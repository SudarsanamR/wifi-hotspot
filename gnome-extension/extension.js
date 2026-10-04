/*
 * Wi-Fi Hotspot Toggle — GNOME Shell Quick Settings extension
 *
 * Adds a toggle button to the system menu (Quick Settings panel) that
 * starts / stops the wifi-hotspot backend via passwordless sudo.
 *
 * State sync: every few seconds the extension runs `iw dev` and looks
 * for `type AP` to decide whether the hotspot is up.  The toggle and
 * the panel indicator icon track that state.
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
const POLL_SECONDS = 4;

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
// The toggle button shown in Quick Settings
// ──────────────────────────────────────────────
const HotspotToggle = GObject.registerClass(
class HotspotToggle extends QuickSettings.QuickToggle {
    constructor() {
        super({
            title: 'Hotspot',
            iconName: 'network-wireless-hotspot-symbolic',
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
        this._indicator.iconName = 'network-wireless-hotspot-symbolic';
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
        try {
            const r = await execAsync(['iw', 'dev']);
            // The ap0 interface shows "type AP" when the hotspot is running
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
