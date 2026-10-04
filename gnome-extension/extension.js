/*
 * Wi-Fi Hotspot Toggle — GNOME Shell Quick Settings extension
 *
 * Adds a toggle button to the system menu (Quick Settings panel) that
 * starts / stops the wifi-hotspot backend via passwordless sudo.
 *
 * State sync: every few seconds the extension reads /run/hotspot-status
 * (written by the wifi-hotspot watcher) to get the hotspot state and
 * connected clients.  Falls back to `iw dev` if the file is missing.
 *
 * Requires: wifi-hotspot installed with its sudoers rule
 *           (sudo -n wifi-hotspot start / stop must work without a password).
 *
 * GNOME Shell 45 – 50  (ESM modules, QuickToggle API)
 */

import GObject from 'gi://GObject';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';

const BIN = '/usr/local/sbin/wifi-hotspot';
const STATUS_FILE = '/run/hotspot-status';
const POLL_SECONDS = 4;

// Icon for the panel indicator and Quick Settings toggle.
// 'network-wireless-symbolic' shows classic WiFi waves — instantly
// recognizable as wireless/hotspot, unlike the default hotspot icon
// which looks like overlapping rectangles (easily confused with settings).
const ICON_NAME = 'network-wireless-symbolic';

// ──────────────────────────────────────────────
// Run a command asynchronously, return a Promise
// ──────────────────────────────────────────────
function execAsync(argv) {
    return new Promise((resolve, reject) => {
        try {
            const proc = new Gio.Subprocess({
                argv,
                flags: Gio.SubprocessFlags.STDOUT_PIPE |
                       Gio.SubprocessFlags.STDERR_PIPE,
            });
            proc.init(null);
            proc.communicate_utf8_async(null, null, (_proc, result) => {
                try {
                    const [, stdout, stderr] = _proc.communicate_utf8_finish(result);
                    const exitOk = _proc.get_successful();
                    resolve({ok: exitOk, stdout: stdout?.trim() ?? '', stderr: stderr?.trim() ?? ''});
                } catch (e) {
                    reject(e);
                }
            });
        } catch (e) {
            reject(e);
        }
    });
}

// ──────────────────────────────────────────────
// Parse /run/hotspot-status for client info
// ──────────────────────────────────────────────
function readStatusFile() {
    try {
        const [ok, contents] = GLib.file_get_contents(STATUS_FILE);
        if (!ok) return null;

        const text = new TextDecoder().decode(contents);
        const lines = text.split('\n');
        const clients = [];

        for (const line of lines) {
            if (line.startsWith('CLIENT\t')) {
                // CLIENT\tMAC\tIP\tNAME\tRX\tTX\tRXSPEED\tTXSPEED
                const parts = line.split('\t');
                if (parts.length >= 4) {
                    clients.push({
                        mac: parts[1],
                        ip: parts[2],
                        name: parts[3] || parts[2], // fall back to IP if no name
                    });
                }
            }
        }

        return {up: true, clients};
    } catch (_e) {
        return null; // file doesn't exist = hotspot is off
    }
}

// ──────────────────────────────────────────────
// The toggle button shown in Quick Settings
// ──────────────────────────────────────────────
const HotspotToggle = GObject.registerClass(
class HotspotToggle extends QuickSettings.QuickToggle {
    constructor() {
        super({
            title: 'Hotspot',
            iconName: ICON_NAME,
            toggleMode: true,
        });
        this._busy = false;
        this.connect('clicked', () => this._onClicked());
    }

    async _onClicked() {
        if (this._busy) return;
        this._busy = true;
        this.subtitle = this.checked ? 'Starting…' : 'Stopping…';

        const action = this.checked ? 'start' : 'stop';
        try {
            const r = await execAsync(['sudo', '-n', BIN, action]);
            if (!r.ok)
                log(`wifi-hotspot ${action} failed: ${r.stderr || r.stdout}`);
        } catch (e) {
            logError(e, `wifi-hotspot ${action}`);
        }
        this._busy = false;
        // The poll timer will update the visual state shortly.
    }
});

// ──────────────────────────────────────────────
// System indicator: panel icon + toggle
// ──────────────────────────────────────────────
const HotspotIndicator = GObject.registerClass(
class HotspotIndicator extends QuickSettings.SystemIndicator {
    constructor(extensionObject) {
        super();

        // Panel icon (only visible when the hotspot is up)
        this._indicator = this._addIndicator();
        this._indicator.iconName = ICON_NAME;
        this._indicator.visible = false;

        // Quick Settings toggle
        this._toggle = new HotspotToggle();
        this.quickSettingsItems.push(this._toggle);

        // Poll for state
        this._pollId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            POLL_SECONDS,
            () => { this._syncState(); return GLib.SOURCE_CONTINUE; }
        );
        // Immediate first check
        this._syncState();
    }

    async _syncState() {
        // Try the status file first (written by the watcher, has client info)
        const status = readStatusFile();

        if (status) {
            // Hotspot is up — status file exists
            this._indicator.visible = true;
            this._toggle.set({checked: true});

            const n = status.clients.length;
            if (n === 0) {
                this._toggle.subtitle = 'On · No devices';
            } else if (n === 1) {
                this._toggle.subtitle = status.clients[0].name;
            } else {
                // Show first device name + count
                this._toggle.subtitle = `${status.clients[0].name} + ${n - 1} more`;
            }
            return;
        }

        // Fallback: check iw dev for AP interface
        try {
            const r = await execAsync(['iw', 'dev']);
            const up = r.ok && /\btype AP\b/.test(r.stdout);
            this._indicator.visible = up;
            this._toggle.set({checked: up});
            this._toggle.subtitle = up ? 'Connected' : '';
        } catch (e) {
            // iw not installed or similar: leave the toggle alone
        }
    }

    destroy() {
        if (this._pollId) {
            GLib.source_remove(this._pollId);
            this._pollId = 0;
        }
        this.quickSettingsItems.forEach(item => item.destroy());
        super.destroy();
    }
});

// ──────────────────────────────────────────────
// Extension entry point
// ──────────────────────────────────────────────
export default class WifiHotspotExtension extends Extension {
    enable() {
        this._indicator = new HotspotIndicator(this);
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
