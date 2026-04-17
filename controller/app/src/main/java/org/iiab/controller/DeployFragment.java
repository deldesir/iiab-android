/*
 * ============================================================================
 * Name        : DeployFragment.java
 * Author      : IIAB Project
 * Copyright   : Copyright (c) 2026 IIAB Project
 * Description : Installation / deployment view
 * ============================================================================
 */
package org.iiab.controller;

import android.content.res.ColorStateList;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.Fragment;

import com.google.android.material.snackbar.Snackbar;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.List;

public class DeployFragment extends Fragment {

    // --- UI Variables ---
    private TextView advancedTitle;
    private LinearLayout advancedContainer;
    private LinearLayout rolesContainer;
    private LinearLayout discrepancyWarning;
    private Button btnLaunchInstall;
    private Button btnFastInstall;
    private Button btnFastDelete;
    private Button btnAdvancedReset;
    private Button btnAdvancedBackup;

    // --- State Management ---
    private final List<CheckBox> newInstallCheckboxes = new ArrayList<>();
    private File sharedStateDir;
    private JSONObject lastKnownState = new JSONObject();
    private LinearLayout btnRefreshModules;
    private static final String TAG = "IIAB-DeployFragment";
    private List<String> installationQueue = new ArrayList<>();
    private boolean isBatchInstalling = false;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        return inflater.inflate(R.layout.fragment_deploy, container, false);
    }

    @Override
    public void onViewCreated(@NonNull View view, @Nullable Bundle savedInstanceState) {
        super.onViewCreated(view, savedInstanceState);

        advancedTitle = view.findViewById(R.id.install_advanced_title);
        advancedContainer = view.findViewById(R.id.advanced_gathering_container);
        rolesContainer = view.findViewById(R.id.install_roles_container);
        discrepancyWarning = view.findViewById(R.id.install_discrepancy_warning);
        btnLaunchInstall = view.findViewById(R.id.btn_launch_install);

        // Link fast install / delete buttons
        btnFastInstall = view.findViewById(R.id.btn_fast_install);
        btnFastDelete = view.findViewById(R.id.btn_fast_delete);

        btnAdvancedReset = view.findViewById(R.id.btn_advanced_reset);
        btnAdvancedBackup = view.findViewById(R.id.btn_advanced_backup);

        sharedStateDir = new File(Environment.getExternalStorageDirectory(), ".iiab_state");

        // Initial Button State
        btnLaunchInstall.setEnabled(false);
        btnLaunchInstall.setAlpha(0.5f);

        setupAdvancedGatheringMenu();
        createModulesGrid();

        // --- FAST INSTALLATION BUTTON ACTIONS ---
        btnFastInstall.setOnClickListener(v -> {
            if (getActivity() instanceof MainActivity) {
                Snackbar.make(v, "Starting fast installation (pull-rootfs)...", Snackbar.LENGTH_SHORT).show();
                ((MainActivity) getActivity()).executeTermuxCommandHeadless("--pull-rootfs");
            }
        });
        btnFastDelete.setOnClickListener(v -> {
            if (getActivity() instanceof MainActivity) {
                Snackbar.make(v, "Starting deletion (remove-rootfs)...", Snackbar.LENGTH_SHORT).show();
                ((MainActivity) getActivity()).executeTermuxCommandHeadless("--remove-rootfs");
            }
        });

        btnAdvancedBackup.setOnClickListener(v -> {
            if (getActivity() instanceof MainActivity) {
                Snackbar.make(v, "Starting backup (backup-rootfs)...", Snackbar.LENGTH_SHORT).show();
                ((MainActivity) getActivity()).executeTermuxCommandHeadless("--backup-rootfs");
            }
        });

        // --- ADVANCED SETUP BUTTON ACTIONS ---
        btnAdvancedReset.setOnClickListener(v -> {
            new android.app.AlertDialog.Builder(requireContext())
                    .setTitle(R.string.install_dialog_reset_title)
                    .setMessage(R.string.install_dialog_reset_msg)
                    .setPositiveButton(R.string.install_dialog_reset_confirm, (dialog, which) -> {
                        if (getActivity() instanceof MainActivity) {
                            Snackbar.make(v, "Starting reset (reset-iiab)...", Snackbar.LENGTH_SHORT).show();
                            ((MainActivity) getActivity()).executeTermuxCommandHeadless("--reset-iiab");
                        }
                    })
                    .setNegativeButton(R.string.install_dialog_reset_cancel, null)
                    .show();
        });
        // Button refresh
        btnRefreshModules = view.findViewById(R.id.btn_refresh_modules);
        btnRefreshModules.setOnClickListener(v -> {
            v.setAlpha(0.5f);
            requestFreshLocalVars();
            new Handler(Looper.getMainLooper()).postDelayed(() -> v.setAlpha(1.0f), 1000);
        });
        requestFreshLocalVarsSilently();
    }

    @Override
    public void onResume() {
        super.onResume();
        // Hide warning initially
        if (discrepancyWarning != null) discrepancyWarning.setVisibility(View.GONE);

        // Restore the memory queue
        restoreQueueFromPrefs();

        if (isBatchInstalling) {
            new Handler(Looper.getMainLooper()).postDelayed(this::processNextInQueue, 500);
        }

        if (lastKnownState.length() > 0) {
            verifyInstallationState(lastKnownState);
        } else {

            File jsonFile = new File(sharedStateDir, "local_vars.json");
            if (jsonFile.exists() && jsonFile.length() > 0) {
                try {
                    StringBuilder text = new StringBuilder();
                    BufferedReader br = new BufferedReader(new FileReader(jsonFile));
                    String line;
                    while ((line = br.readLine()) != null) {
                        text.append(line);
                    }
                    br.close();
                    lastKnownState = new JSONObject(text.toString());
                    verifyInstallationState(lastKnownState);
                } catch (Exception e) {
                    android.util.Log.e(TAG, "Failed to read existing JSON in onResume", e);
                }
            }
        }
    }

    private void setupAdvancedGatheringMenu() {
        advancedContainer.setVisibility(View.GONE);
        advancedTitle.setText("▶ " + getString(R.string.install_adv_gathering_title));

        advancedTitle.setOnClickListener(v -> {
            boolean isCollapsed = advancedContainer.getVisibility() == View.GONE;
            if (isCollapsed) {
                advancedContainer.setVisibility(View.VISIBLE);
                advancedTitle.setText("▼ " + getString(R.string.install_adv_gathering_title));
            } else {
                advancedContainer.setVisibility(View.GONE);
                advancedTitle.setText("▶ " + getString(R.string.install_adv_gathering_title));
            }
        });
    }

    private void createModulesGrid() {
        if (rolesContainer == null || getContext() == null) return;
        rolesContainer.removeAllViews();
        newInstallCheckboxes.clear();

        String termuxArch = getTermuxArch();
        boolean is64Bit = termuxArch != null && termuxArch.contains("64");

        List<ModuleRegistry.IiabModule> activeModules = new ArrayList<>();
        for (ModuleRegistry.IiabModule module : ModuleRegistry.MASTER_ROSTER) {
            if (module.requires64Bit && !is64Bit) continue;
            activeModules.add(module);
        }

        int numCols = 3;
        int numRows = (int) Math.ceil((double) activeModules.size() / numCols);

        int ledSizePx = (int) (12 * getResources().getDisplayMetrics().density);

        for (int row = 0; row < numRows; row++) {
            LinearLayout rowLayout = new LinearLayout(requireContext());
            rowLayout.setOrientation(LinearLayout.HORIZONTAL);
            rowLayout.setLayoutParams(new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
            rowLayout.setBaselineAligned(false);
            rowLayout.setWeightSum(numCols);
            rowLayout.setPadding(0, 0, 0, 16);

            for (int col = 0; col < numCols; col++) {
                int index = (row * numCols) + col;

                LinearLayout cell = new LinearLayout(requireContext());
                LinearLayout.LayoutParams cellParams = new LinearLayout.LayoutParams(
                        0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);

                int margin = 10;
                if (col == 0) cellParams.setMargins(0, 0, margin, 0);
                else if (col == 1) cellParams.setMargins(margin / 2, 0, margin / 2, 0);
                else cellParams.setMargins(margin, 0, 0, 0);

                cell.setLayoutParams(cellParams);

                if (index < activeModules.size()) {
                    ModuleRegistry.IiabModule currentMod = activeModules.get(index);

                    cell.setOrientation(LinearLayout.HORIZONTAL);
                    cell.setBackgroundResource(R.drawable.rounded_button);
                    cell.setBackgroundTintList(ColorStateList.valueOf(
                            ContextCompat.getColor(requireContext(), R.color.dash_module_bg)));
                    cell.setPadding(16, 28, 16, 28);
                    cell.setGravity(android.view.Gravity.CENTER);

                    int boxSizePx = (int) (24 * getResources().getDisplayMetrics().density);
                    android.widget.FrameLayout indicatorContainer = new android.widget.FrameLayout(requireContext());
                    LinearLayout.LayoutParams indParams = new LinearLayout.LayoutParams(boxSizePx, boxSizePx);
                    indicatorContainer.setLayoutParams(indParams);

                    View led = new View(requireContext());
                    android.widget.FrameLayout.LayoutParams ledParams = new android.widget.FrameLayout.LayoutParams(
                            ledSizePx, ledSizePx, android.view.Gravity.CENTER);
                    led.setLayoutParams(ledParams);
                    led.setBackgroundResource(R.drawable.led_off);

                    CheckBox checkBox = new CheckBox(requireContext());
                    checkBox.setScaleX(0.85f);
                    checkBox.setScaleY(0.85f);
                    checkBox.setPadding(0, 0, 0, 0);
                    android.widget.FrameLayout.LayoutParams cbParams = new android.widget.FrameLayout.LayoutParams(
                            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, android.view.Gravity.CENTER);
                    checkBox.setLayoutParams(cbParams);
                    checkBox.setVisibility(View.GONE);

                    indicatorContainer.addView(led);
                    indicatorContainer.addView(checkBox);

                    TextView name = new TextView(requireContext());
                    name.setText(getString(currentMod.nameResId));
                    name.setTextColor(ContextCompat.getColor(requireContext(), R.color.dash_text_primary));
                    name.setTextSize(12f);
                    name.setSingleLine(true);

                    LinearLayout.LayoutParams textParams = new LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                    textParams.setMargins(16, 0, 0, 0);
                    name.setLayoutParams(textParams);

                    cell.addView(indicatorContainer);
                    cell.addView(name);

                    cell.setTag(currentMod);
                } else {
                    cell.setVisibility(View.INVISIBLE);
                }

                rowLayout.addView(cell);
            }
            rolesContainer.addView(rowLayout);
        }
    }

    // --- LOGIC: REQUEST FRESH JSON ---
    private void requestFreshLocalVars() {
        File jsonFile = new File(sharedStateDir, "local_vars.json");

        if (jsonFile.exists() && jsonFile.length() > 0) {
            try {
                StringBuilder text = new StringBuilder();
                BufferedReader br = new BufferedReader(new FileReader(jsonFile));
                String line;
                while ((line = br.readLine()) != null) {
                    text.append(line);
                }
                br.close();
                lastKnownState = new JSONObject(text.toString());
            } catch (Exception e) {
                android.util.Log.e(TAG, "Failed to cache old JSON", e);
            }
        }

        if (jsonFile.exists()) {
            jsonFile.delete();
        }

        if (getActivity() instanceof MainActivity) {
            ((MainActivity) getActivity()).executeTermuxCommandHeadless("--json-vars");
        }

        pollForJsonFile(jsonFile, 10, 1000); // 10 attempts, 1000ms each = 10 seconds
    }
    private void requestFreshLocalVarsSilently() {
        File jsonFile = new File(sharedStateDir, "local_vars.json");
        if (jsonFile.exists() && jsonFile.length() > 0) {
            try {
                StringBuilder text = new StringBuilder();
                BufferedReader br = new BufferedReader(new FileReader(jsonFile));
                String line;
                while ((line = br.readLine()) != null) text.append(line);
                br.close();
                lastKnownState = new JSONObject(text.toString());
                verifyInstallationState(lastKnownState);
            } catch (Exception e) {
                android.util.Log.e(TAG, "Failed to read existing JSON silently", e);
            }
        }
    }

    private void pollForJsonFile(File jsonFile, int attemptsLeft, int delayMs) {
        if (attemptsLeft <= 0) {
            android.util.Log.w(TAG, "TIMEOUT: local_vars.json never appeared. Using cached state.");
            verifyInstallationState(lastKnownState);
            return;
        }

        if (jsonFile.exists() && jsonFile.length() > 0) {
            android.util.Log.d(TAG, "SUCCESS: Found fresh local_vars.json!");
            try {
                StringBuilder text = new StringBuilder();
                BufferedReader br = new BufferedReader(new FileReader(jsonFile));
                String line;
                while ((line = br.readLine()) != null) {
                    text.append(line);
                }
                br.close();

                JSONObject freshVars = new JSONObject(text.toString());
                lastKnownState = freshVars;
                verifyInstallationState(freshVars);
                return;
            } catch (Exception e) {
                android.util.Log.e(TAG, "Failed to parse fresh JSON", e);
                verifyInstallationState(lastKnownState);
                return;
            }
        }

        // KEEP WAITING
        new Handler(android.os.Looper.getMainLooper()).postDelayed(() ->
                pollForJsonFile(jsonFile, attemptsLeft - 1, delayMs), delayMs);
    }

    // --- LOGIC: VERIFY AND COLORIZE ---
    private void verifyInstallationState(JSONObject jsonVars) {
        new Thread(() -> {
            if (!isAdded() || getActivity() == null || rolesContainer == null) return;

            boolean isMainServerAlive = pingUrl("http://localhost:8085/home");
            boolean discrepancyFound = false;

            for (int r = 0; r < rolesContainer.getChildCount(); r++) {
                LinearLayout row = (LinearLayout) rolesContainer.getChildAt(r);

                for (int c = 0; c < row.getChildCount(); c++) {
                    LinearLayout card = (LinearLayout) row.getChildAt(c);
                    ModuleRegistry.IiabModule module = (ModuleRegistry.IiabModule) card.getTag();
                    if (module == null) continue;

                    android.widget.FrameLayout indicatorContainer = (android.widget.FrameLayout) card.getChildAt(0);
                    View led = indicatorContainer.getChildAt(0);
                    CheckBox checkBox = (CheckBox) indicatorContainer.getChildAt(1);

                    boolean isInstallTrue = jsonVars.optBoolean(module.yamlBaseKey + "_install", false);
                    boolean isEnabledTrue = jsonVars.optBoolean(module.yamlBaseKey + "_enabled", false);
                    boolean yamlState = isInstallTrue || isEnabledTrue;

                    boolean pingState = isMainServerAlive && pingUrl("http://localhost:8085/" + module.endpoint);

                    final boolean finalYaml = yamlState;
                    final boolean finalPing = pingState;

                    getActivity().runOnUiThread(() -> {
                        card.setOnClickListener(null);
                        checkBox.setOnCheckedChangeListener(null);

                        if (finalYaml && finalPing) {
                            // RULE 1: Confirmed -> Show Green LED
                            checkBox.setVisibility(View.GONE);
                            led.setVisibility(View.VISIBLE);
                            led.setBackgroundTintList(null);
                            led.setBackgroundResource(R.drawable.led_on_green);

                            card.setOnClickListener(v -> Snackbar.make(v, R.string.install_msg_confirmed, Snackbar.LENGTH_LONG).show());
                        } else if (finalYaml != finalPing) {
                            // RULE 2: Discrepancy -> Display Yellow/Orange LED
                            checkBox.setVisibility(View.GONE);
                            led.setVisibility(View.VISIBLE);
                            led.setBackgroundResource(R.drawable.led_off);
                            led.setBackgroundTintList(ColorStateList.valueOf(Color.parseColor("#FFC107")));

                            card.setOnClickListener(v -> Snackbar.make(v, R.string.install_warning_discrepancy_msg, Snackbar.LENGTH_LONG).show());
                        } else {
                            // RULE 3: Available -> Hide LED, Show White CheckBox
                            led.setVisibility(View.GONE);
                            checkBox.setVisibility(View.VISIBLE);

                            checkBox.setChecked(false);
                            checkBox.setEnabled(true);
                            checkBox.setButtonTintList(ColorStateList.valueOf(Color.WHITE));

                            card.setOnClickListener(v -> checkBox.toggle());

                            if (!newInstallCheckboxes.contains(checkBox)) {
                                newInstallCheckboxes.add(checkBox);
                            }

                            checkBox.setOnCheckedChangeListener((buttonView, isChecked) -> evaluateLaunchButton());
                        }
                    });

                    if (finalYaml != finalPing) {
                        discrepancyFound = true;
                    }
                }
            }

            final boolean finalDiscrepancy = discrepancyFound;
            getActivity().runOnUiThread(() -> {
                if (discrepancyWarning != null) {
                    discrepancyWarning.setVisibility(finalDiscrepancy ? View.VISIBLE : View.GONE);
                }
                evaluateLaunchButton();
            });

        }).start();
    }

    private void evaluateLaunchButton() {
        if (isBatchInstalling) return;

        boolean hasSelections = false;
        installationQueue.clear();

        for (CheckBox cb : newInstallCheckboxes) {
            if (cb.isChecked()) {
                hasSelections = true;
                ViewGroup indicatorContainer = (ViewGroup) cb.getParent();
                ViewGroup card = (ViewGroup) indicatorContainer.getParent();
                ModuleRegistry.IiabModule module = (ModuleRegistry.IiabModule) card.getTag();

                if (module != null) {
                    installationQueue.add(module.yamlBaseKey);
                }
            }
        }

        btnLaunchInstall.setEnabled(hasSelections);
        btnLaunchInstall.setAlpha(hasSelections ? 1.0f : 0.5f);
        btnLaunchInstall.setText(getString(R.string.install_btn_launch));

        if (hasSelections) {
            btnLaunchInstall.setOnClickListener(v -> {
                isBatchInstalling = true;
                saveQueueToPrefs();
                processNextInQueue();
            });
        } else {
            btnLaunchInstall.setOnClickListener(null);
        }
    }

    private boolean pingUrl(String urlStr) {
        try {
            URL url = new URL(urlStr);
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setUseCaches(false);
            conn.setInstanceFollowRedirects(false);
            conn.setConnectTimeout(1500);
            conn.setReadTimeout(1500);
            conn.setRequestMethod("HEAD");
            int responseCode = conn.getResponseCode();
            return (responseCode >= 200 && responseCode < 400);
        } catch (Exception e) {
            return false;
        }
    }

    private String getTermuxArch() {
        try {
            android.content.pm.ApplicationInfo info = requireContext().getPackageManager().getApplicationInfo("com.termux", 0);
            String nativeLibDir = info.nativeLibraryDir;

            if (nativeLibDir != null) {
                if (nativeLibDir.endsWith("arm64")) return "arm64-v8a";
                if (nativeLibDir.endsWith("arm")) return "armeabi-v7a";
                if (nativeLibDir.endsWith("x86_64")) return "x86_64";
                if (nativeLibDir.endsWith("x86")) return "x86";
            }
        } catch (android.content.pm.PackageManager.NameNotFoundException e) {
            return "N/A";
        }

        if (android.os.Build.SUPPORTED_ABIS.length > 0) {
            return android.os.Build.SUPPORTED_ABIS[0];
        }
        return "unknown";
    }

    // --- METHODS FOR PERSISTING THE INSTALLATION QUEUE ---
    private void saveQueueToPrefs() {
        if (getActivity() == null) return;
        android.content.SharedPreferences prefs = getActivity().getSharedPreferences("iiab_queue_prefs", android.content.Context.MODE_PRIVATE);
        String queueString = android.text.TextUtils.join(",", installationQueue);
        prefs.edit().putString("pending_modules", queueString).putBoolean("is_batch_installing", isBatchInstalling).apply();
    }

    private void restoreQueueFromPrefs() {
        if (getActivity() == null) return;
        android.content.SharedPreferences prefs = getActivity().getSharedPreferences("iiab_queue_prefs", android.content.Context.MODE_PRIVATE);
        isBatchInstalling = prefs.getBoolean("is_batch_installing", false);
        String queueString = prefs.getString("pending_modules", "");

        installationQueue.clear();
        if (!queueString.isEmpty()) {
            String[] modules = queueString.split(",");
            installationQueue.addAll(java.util.Arrays.asList(modules));
        }
    }

    // --- QUEUE DIRECTOR ---
    private void processNextInQueue() {
        if (installationQueue.isEmpty()) {
            // The queue is empty! We're finished.
            isBatchInstalling = false;
            saveQueueToPrefs();

            // We re-enable the UI and refresh the final JSON
            btnLaunchInstall.setEnabled(false);
            btnLaunchInstall.setText(getString(R.string.install_btn_launch));
            requestFreshLocalVars();

            if (getView() != null) {
                Snackbar.make(getView(), R.string.install_msg_finished, Snackbar.LENGTH_LONG).show();
            }
            return;
        }

        // We remove the FIRST element from the queue
        String nextModule = installationQueue.remove(0);
        saveQueueToPrefs();

        android.util.Log.d(TAG, "Queue: Sending module to Termux -> " + nextModule);

        // We've blocked the UI so the user knows what's going on.
        btnLaunchInstall.setEnabled(false);
        btnLaunchInstall.setText("Installing " + nextModule + "...");

        // We launch the Termux command
        if (getActivity() instanceof MainActivity) {
            ((MainActivity) getActivity()).executeTermuxCommandHeadless("--install-module " + nextModule);
        }
    }
}