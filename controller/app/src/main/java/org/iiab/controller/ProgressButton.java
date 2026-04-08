/*
 * ============================================================================
 * Name        : ProgressButton.java
 * Author      : IIAB Project
 * Copyright   : Copyright (c) 2026 IIAB Project
 * Description : Button animation helper
 * ============================================================================
 */
package org.iiab.controller;

import android.animation.ValueAnimator;
import android.content.Context;
import android.content.res.TypedArray;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Path;
import android.util.AttributeSet;

import androidx.core.content.ContextCompat;
import androidx.appcompat.widget.AppCompatButton;

public class ProgressButton extends AppCompatButton {

    private Paint progressPaint;
    private Paint progressBackgroundPaint;

    private int progressColor;
    private int progressBackgroundColor;
    private Path clipPath;
    private RectF rectF;
    private float cornerRadius;
    private int progressHeight;

    // Animation variables
    private float currentProgress = 0f;
    private boolean isRunning = false;
    private ValueAnimator animator;

    public ProgressButton(Context context) {
        super(context);
        init(context, null);
    }

    public ProgressButton(Context context, AttributeSet attrs) {
        super(context, attrs);
        init(context, attrs);
    }

    public ProgressButton(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
        init(context, attrs);
    }

    private void init(Context context, AttributeSet attrs) {
        if (attrs != null) {
            TypedArray a = context.obtainStyledAttributes(attrs, R.styleable.ProgressButton, 0, 0);
            try {
                progressColor = a.getColor(R.styleable.ProgressButton_progressButtonColor, ContextCompat.getColor(context, R.color.btn_danger));
                progressBackgroundColor = a.getColor(R.styleable.ProgressButton_progressButtonBackgroundColor, Color.parseColor("#44888888"));
                progressHeight = a.getDimensionPixelSize(R.styleable.ProgressButton_progressButtonHeight, (int) (6 * getResources().getDisplayMetrics().density));
                // Note: We no longer read 'duration' from XML because the animation is infinite.
            } finally {
                a.recycle();
            }
        } else {
            // Safe defaults
            progressColor = ContextCompat.getColor(context, R.color.btn_danger);
            progressBackgroundColor = Color.parseColor("#44888888");
            progressHeight = (int) (6 * getResources().getDisplayMetrics().density);
        }

        progressPaint = new Paint();
        progressPaint.setColor(progressColor);
        progressPaint.setStyle(Paint.Style.FILL);

        progressBackgroundPaint = new Paint();
        progressBackgroundPaint.setColor(progressBackgroundColor);
        progressBackgroundPaint.setStyle(Paint.Style.FILL);

        // Initialize clipping path variables
        clipPath = new Path();
        rectF = new RectF();
        cornerRadius = 8 * getResources().getDisplayMetrics().density;
    }

    @Override
    protected void onDraw(Canvas canvas) {
        // Draw the background and text first
        super.onDraw(canvas);

        // Draw the progress bar constrained by the button's rounded corners
        if (progressHeight > 0 && isRunning) {
            int buttonWidth = getWidth();
            int buttonHeight = getHeight();

            // Calculate width based on the current animated float (0.0f to 1.0f)
            int progressWidth = (int) (buttonWidth * currentProgress);

            // 1. Prepare the rounded mask (matches the button's bounds)
            rectF.set(0, 0, buttonWidth, buttonHeight);
            clipPath.reset();
            clipPath.addRoundRect(rectF, cornerRadius, cornerRadius, Path.Direction.CW);

            // 2. Save canvas state and apply the mask
            canvas.save();
            canvas.clipPath(clipPath);

            // 3. Draw the tracks
            canvas.drawRect(0, buttonHeight - progressHeight, buttonWidth, buttonHeight, progressBackgroundPaint);
            canvas.drawRect(0, buttonHeight - progressHeight, progressWidth, buttonHeight, progressPaint);

            // 4. Restore canvas
            canvas.restore();
        }
    }

    /**
     * Starts an infinite cyclic animation (fills and empties the bar).
     * Disables the button to prevent spam clicks.
     */
    public void startProgress() {
        if (isRunning) return;
        isRunning = true;
        setEnabled(false); // Lock the button immediately

        // Create an animator that goes from 0.0 to 1.0 (empty to full)
        animator = ValueAnimator.ofFloat(0f, 1f);
        animator.setDuration(1200); // 1.2 seconds per sweep
        animator.setRepeatMode(ValueAnimator.REVERSE); // Fill up, then empty down
        animator.setRepeatCount(ValueAnimator.INFINITE); // Never stop until commanded

        animator.addUpdateListener(animation -> {
            currentProgress = (float) animation.getAnimatedValue();
            invalidate(); // Force redraw on every frame
        });

        animator.start();
    }

    /**
     * Stops the animation, clears the bar, and unlocks the button.
     * To be called by the Controller when the backend confirms the state change.
     */
    public void stopProgress() {
        if (animator != null && animator.isRunning()) {
            animator.cancel();
        }
        isRunning = false;
        setEnabled(true); // Unlock button
        currentProgress = 0f; // Reset width
        invalidate(); // Clear the bar visually
    }
}