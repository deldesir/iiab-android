# :world_map: Internet-in-a-Box on Android

**[Internet-in-a-Box (IIAB)](https://internet-in-a-box.org) on Android** will allow millions of people worldwide to build their own family libraries, inside their own phones!

As of January 2026, these IIAB Apps are supported:

* **Calibre-Web** (eBooks & videos)
* **Kiwix** (Wikipedias, etc)
* **Kolibri** (lessons & quizzes)
* **Maps** (satellite photos, terrain, buildings)
* **Matomo** (metrics)

The default port for the web server is **8085**, for example:

```
http://localhost:8085/maps
```

## What are the current components of "IIAB on Android"?

- **[termux-setup](https://github.com/iiab/iiab-android/tree/main/termux-setup) (iiab-termux)** — sets up a Debian-like environment on Android (it's called [PRoot](https://wiki.termux.com/wiki/PRoot))
- **Wrapper to install IIAB (iiab-android)** — sets up [`local_vars_android.yml`](https://github.com/iiab/iiab/blob/master/vars/local_vars_android.yml), then launches IIAB's installer
- **Core IIAB portability layer** — modifications across IIAB and its existing roles, based on [PR #4122](https://github.com/iiab/iiab/pull/4122)
- **proot-distro service manager (PDSM)** — like systemd, but for `proot_services`

## Related Docs

- **Android bootstrap (in this repo):** [`termux-setup/README.md`](./termux-setup/README.md)
- **proot_services role (in IIAB's main repo):** [`roles/proot_services/README.md`](https://github.com/iiab/iiab/blob/master/roles/proot_services/README.md)

---

## :clipboard: Installation guide

1. Start with an Android 12-or-higher phone or tablet:

   * Install **F-Droid**. It will be our main source for required apps and app updates. As a bonus, there is no need to open an account.
    - [https://f-droid.org/F-Droid.apk](https://f-droid.org/F-Droid.apk)
    - * You will have to Allow installation from unknown sources (or Install unknown apps) from Chrome

   * Update the **F-Droid repos**.
     - Open the F-Droid app and click "Updates".
   * Search for **Termux** and install:
     - **Termux** Terminal emulator with packages (com.termux)
     - **Termux:API** Access Android functions from Termux (com.termux.api)
     - * You will have to Allow installation from unknown sources (or Install unknown apps) from F-Droid

   **Note**: You might see a "*This app was built for an older version of Android and cannot be updated automatically*" label on both apps. You can ignore this as it only refers for the [*auto-update* feature](https://f-droid.org/en/2024/02/01/twif.html). Manual updates will continue to work. [Read more here](https://github.com/termux/termux-packages/wiki/Termux-and-Android-10/3e8102ecd05c4954d67971ff2b508f32900265f7).

2. Enable **Developer Options** on Android:

   * In **Settings > About phone** (or **About tablet**, or **Software information**), find the **Build number** (or **Software version**), and tap it seven times rapidly!

3. Prepare the Termux environment. Android 12 and later versions have a feature called ["Phantom Process Killer" (PPK)](https://github.com/agnostic-apollo/Android-Docs/blob/master/en/docs/apps/processes/phantom-cached-and-empty-processes.md), which limits child processes. We need to disable this restriction to run IIAB successfully. In Android 12 and 13, you will disable PPK as part of the Termux environment set up as there is no UI option. For Android 14+, you can disable the restriction using Android Settings (see below). 

   On all Android versions, run the following: 
   ```
   curl iiab.io/termux.txt | bash
   ```
   * In Android 12 and 13, make sure to opt in to the ADB Pair/Connect steps when prompted. You will be asked for 3 values: **Connect Port**, **Pair Port**, and **Pair Code**. Please check this (WIP) [video tutorial](https://ark.switnet.org/vid/termux_adb_pair_a16_hb.mp4) for a more interactive explanation. Once connected to ADB the `iiab-termux` script will handle the PPK workaround setup.
   
   * On Android 14 and later: Disable this restriction using Android Settings, in **Developer Options**:

        * `Disable child process restrictions` (English), or
        * `Desactivar restricciones de procesos secundarios` (Spanish)

4. Enter [PRoot Distro](https://wiki.termux.com/wiki/PRoot)'s IIAB Debian environment to continue the installation:

     ```
     iiab-termux --login
     ```

5. Run `iiab-android` which (a) installs `local_vars_android.yml` to [`/etc/iiab/local_vars.yml`](https://wiki.iiab.io/go/FAQ#What_is_local_vars.yml_and_how_do_I_customize_it?) and then (b) runs the IIAB installer:

   ```
   iiab-android
   ```

   If the installer completes successfully, you'll see a text box reading:

   > INTERNET-IN-A-BOX (IIAB) SOFTWARE INSTALL IS COMPLETE

## Test your IIAB install

Test your IIAB install by running the `pdsm` command as follows: ([learn more](https://github.com/iiab/iiab/tree/master/roles/proot_services#proot-distro-service-manager-pdsm))

```
pdsm start-all
```

Then check that your IIAB Apps are working (using a browser on your Android device) by visiting these URLs:

| App                    | URL                                                            |
|------------------------|----------------------------------------------------------------|
| Calibre-Web            | [http://localhost:8085/books](http://localhost:8085/books)     |
| Kiwix (for ZIM files!) | [http://localhost:8085/kiwix](http://localhost:8085/kiwix)     |
| Kolibri                | [http://localhost:8085/kolibri](http://localhost:8085/kolibri) |
| IIAB Maps              | [http://localhost:8085/maps](http://localhost:8085/maps)       |
| Matomo                 | [http://localhost:8085/matomo](http://localhost:8085/matomo)   |

If you encounter an error or problem, please open an [issue](https://github.com/iiab/iiab/issues) so we can help you (and others) as quickly as possible.

### Add a ZIM file

A copy of Wikipedia (in almost any language) can now be put on your Android phone or tablet! Here's how...

1. Browse to website: [download.kiwix.org/zim](https://download.kiwix.org/zim/)
2. Pick a `.zim` file (ZIM file) and copy its full URL, for example:

   ``` 
   https://download.kiwix.org/zim/wikipedia/wikipedia_en_100_maxi_2026-01.zim
   ```

3. Open Android's Termux app, and then run:

   ```
   iiab-termux --login iiab
   ```

   EXPLANATION: Starting from Termux's high-level CLI (Command-Line Interface), you've "shelled into" [PRoot Distro](https://wiki.termux.com/wiki/PRoot)'s low-level IIAB Debian CLI:

   ```
         +--------------------------------+
         |  Android GUI (Apps, Settings)  |
         +----------------+---------------+
                          |
                 open the | Termux app
                          v
         +----------------+---------------+
         |      Termux (Android CLI)      |
         | $ proot-distro login iiab      |
         +----------------+---------------+
                          |
         "shell into" the | low-level environment
                          v
      +-------------------+-------------------+
      | proot-distro: IIAB Debian (userspace) |
      | debian root# cd /opt/iiab/iiab        |
      +---------------------------------------+
   ```

4. Enter the folder where IIAB stores ZIM files:

   ```
   cd /library/zims/content/
   ```

5. Download the ZIM file, using the URL you chose above, for example:

   ```
   wget https://download.kiwix.org/zim/wikipedia/wikipedia_en_100_maxi_2026-01.zim
   ```

6. Once the download is complete, re-index your IIAB's ZIM files: (so the new ZIM file appears for users, on page http://localhost:8085/kiwix)

   ```
   iiab-make-kiwix-lib
   ```

   TIP: Repeat this last step whenever removing or adding new ZIM files from `/library/zims/content/`

## Remote Access

While using the phone keyboard and screen is practical when on the move, accessing the PRoot Distro's IIAB Debian environment from a PC or laptop is very useful for debugging. You can use an existing Wi-Fi connection or enable the native Android hotspot if no wireless LAN is available.

Before you begin, obtain your Android phone or tablet’s IP address by running `ifconfig` in Termux. Or obtain the IP by checking **About device → Status** in Android settings.

### SSH

To log in to IIAB on Android from your computer, follow these SSH command-line interface (CLI) instructions:

1. On your Android phone or tablet, find your way to Termux's CLI. **If you earlier ran `proot-distro login iiab` to get to PRoot Distro's low-level IIAB Debian CLI — you MUST step back up to Termux's high-level CLI — e.g. by running:**

   ```
   exit
   ```

2. The fastest way to SSH into your Android phone (or tablet) is to set a password for its Termux user. In Termux's high-level CLI, run:

   ```
   passwd
   ```

   Optionally, security can be improved by using standard SSH key-based authentication via the `~/.ssh/authorized_keys` file.

3. Start the SSH service. In Termux's high-level CLI, run:

   ```
   sshd
   ```

   The `sshd` service can be automated to start when Termux launches (see [Termux-services](https://wiki.Termux.com/wiki/Termux-services)). We recommend doing this only after improving login security using SSH keys.

4. SSH to your Android phone.

   From your laptop or PC, connected to the same network as your Android phone, and knowing the phone’s IP address (for example, `192.168.10.100`), you would run:

   ```
   ssh -p 8022 192.168.10.100
   ```

   A username is NOT needed!

   Note that port **8022** is used for SSH. Since Android runs without root permissions, SSH cannot use lower-numbered ports. (For the same reason, the IIAB web server [nginx] uses port **8085** instead of port 80.)

### Log in to the IIAB environment

Once you have an SSH session on your remote device, log into PRoot Distro to access and run the IIAB applications, just as during installation:

```
proot-distro login iiab
```

You will then be in a IIAB Debian shell with access to the IIAB CLI (command-line interface) tools.

## Removal

If you want to remove the IIAB installation and all associated apps, follow these steps:

1. Remove the IIAB installation running in PRoot Distro:

   ```
   proot-distro remove iiab
   ```

   **Note:** All content in that IIAB installation will be deleted when executing this command. Back up your content first if you plan to reinstall later.

2. Remove / uninstall the Termux app.

3. If applicable, remove / uninstall the Shizuku app (Android 12–13).

4. Disable Developer Options.
