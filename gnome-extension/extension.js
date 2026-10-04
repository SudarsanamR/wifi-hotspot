/**
 * Wi-Fi Hotspot GNOME Shell Extension
 *
 * Provides:
 * 1. An icon in the top panel status area ("icon tray") with a popup menu:
 *    - Turn Hotspot On / Off toggle switch
 *    - Live hotspot status & channel
 *    - List of connected devices (showing device names & IPs)
 *    - Launch Hotspot Settings GUI
 * 2. A Quick Settings toggle in the top-right system dropdown menu.
 *
 * State sync: polls /run/hotspot-status (written by backend watcher)
 *             and falls back to `iw dev` if file is missing.
 *
 * Supported: GNOME Shell 45 – 50 (ESM, QuickSettings, PanelMenu)
 */

import GObject from 'gi://GObject';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';

const BIN = '/usr/local/sbin/wifi-hotspot';
const STATUS_FILE = '/run/hotspot-status';
const POLL_SECONDS = 3;

// Classic WiFi wave icon
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
        let ssid = '';
        let channel = '';

        for (const line of lines) {
            if (line.startsWith('CLIENT\t')) {
                // CLIENT\tMAC\tIP\tNAME\tRX\tTX\tRXSPEED\tTXSPEED
                const parts = line.split('\t');
                if (parts.length >= 4) {
                    const mac = parts[1]?.trim() ?? '';
                    const ip = parts[2]?.trim() ?? '';
                    const rawName = parts[3]?.trim() ?? '';
                    let name = rawName;
                    if (!name || name === '-' || name === '*') {
                        name = (ip && ip !== '-') ? ip : mac;
                    }
                    clients.push({ mac, ip, name });
                }
            } else if (line.startsWith('CHANNEL=')) {
                channel = line.split('=')[1]?.trim() ?? '';
            } else if (line.startsWith('SSID=')) {
                ssid = line.split('=')[1]?.trim() ?? '';
            }
        }

        return {up: true, clients, ssid, channel};
    } catch (_e) {
        return null; // file doesn't exist = hotspot is off
    }
}

// ──────────────────────────────────────────────
// 1. Top Panel Tray Indicator & Menu (PanelMenu.Button)
// ──────────────────────────────────────────────
const HotspotPanelButton = GObject.registerClass(
class HotspotPanelButton extends PanelMenu.Button {
    _init(extension) {
        super._init(0.0, 'Wi-Fi Hotspot');
        this._ext = extension;
        this._busy = false;

        this._icon = new St.Icon({
            icon_name: ICON_NAME,
            style_class: 'system-status-icon',
        });
        this.add_child(this._icon);

        this._buildMenu();
    }

    _buildMenu() {
        this.menu.removeAll();

        // Toggle switch item
        this._switchItem = new PopupMenu.PopupSwitchMenuItem('Wi-Fi Hotspot', false);
        this._switchItem.connect('toggled', (_item, state) => {
            this._onToggled(state);
        });
        this.menu.addMenuItem(this._switchItem);

        // Status subtitle item
        this._statusItem = new PopupMenu.PopupMenuItem('Status: Off', {reactive: false});
        this._statusItem.label.clutter_text.set_opacity(160);
        this.menu.addMenuItem(this._statusItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Devices section
        this._devicesSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._devicesSection);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Open GUI action
        const guiItem = new PopupMenu.PopupMenuItem('Hotspot Settings…');
        guiItem.connect('activate', () => {
            try {
                Gio.AppInfo.create_from_commandline(
                    '/usr/local/bin/wifi-hotspot-gui',
                    'Wi-Fi Hotspot',
                    Gio.AppInfoCreateFlags.NONE
                ).launch([], null);
            } catch (e) {
                logError(e, 'Failed to launch wifi-hotspot-gui');
            }
        });
        this.menu.addMenuItem(guiItem);
    }

    async _onToggled(state) {
        if (this._busy) return;
        this._busy = true;
        this._statusItem.label.text = state ? 'Starting…' : 'Stopping…';

        const action = state ? 'start' : 'stop';
        try {
            const r = await execAsync(['sudo', '-n', BIN, action]);
            if (!r.ok)
                log(`wifi-hotspot ${action} failed: ${r.stderr || r.stdout}`);
        } catch (e) {
            logError(e, `wifi-hotspot ${action}`);
        }
        this._busy = false;
        this._ext.syncAll();
    }

    updateState(isUp, clients = [], details = {}) {
        this._switchItem.setToggleState(isUp);
        this._icon.opacity = isUp ? 255 : 170;

        if (isUp) {
            const ch = details.channel ? ` · Ch ${details.channel}` : '';
            this._statusItem.label.text = `Status: Active${ch}`;
        } else {
            this._statusItem.label.text = 'Status: Off';
        }

        // Rebuild devices list
        this._devicesSection.removeAll();
        if (isUp) {
            const n = clients.length;
            const header = new PopupMenu.PopupMenuItem(
                n === 0 ? 'No connected devices' : `Connected Devices (${n}):`,
                {reactive: false}
            );
            header.label.clutter_text.set_opacity(180);
            this._devicesSection.addMenuItem(header);

            for (const c of clients) {
                const devText = c.ip ? `  📱 ${c.name} (${c.ip})` : `  📱 ${c.name}`;
                const item = new PopupMenu.PopupMenuItem(devText, {reactive: false});
                this._devicesSection.addMenuItem(item);
            }
        }
    }
});

// ──────────────────────────────────────────────
// 2. Quick Settings Toggle Button (QuickSettings.QuickToggle)
// ──────────────────────────────────────────────
const HotspotToggle = GObject.registerClass(
class HotspotToggle extends QuickSettings.QuickToggle {
    constructor(extension) {
        super({
            title: 'Hotspot',
            iconName: ICON_NAME,
            toggleMode: true,
        });
        this._ext = extension;
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
        this._ext.syncAll();
    }
});

const HotspotQuickIndicator = GObject.registerClass(
class HotspotQuickIndicator extends QuickSettings.SystemIndicator {
    constructor(extension) {
        super();
        this._ext = extension;

        this._toggle = new HotspotToggle(extension);
        this.quickSettingsItems.push(this._toggle);
    }

    updateState(isUp, clients = []) {
        this._toggle.set({checked: isUp});
        if (isUp) {
            const n = clients.length;
            if (n === 0) {
                this._toggle.subtitle = 'On · No devices';
            } else if (n === 1) {
                this._toggle.subtitle = clients[0].name;
            } else {
                this._toggle.subtitle = `${clients[0].name} + ${n - 1} more`;
            }
        } else {
            this._toggle.subtitle = '';
        }
    }

    destroy() {
        this.quickSettingsItems.forEach(item => item.destroy());
        super.destroy();
    }
});

// ──────────────────────────────────────────────
// Extension Entry Point
// ──────────────────────────────────────────────
export default class WifiHotspotExtension extends Extension {
    enable() {
        // 1. Add tray button to top panel status area ("icon tray")
        this._trayButton = new HotspotPanelButton(this);
        Main.panel.addToStatusArea(this.uuid, this._trayButton);

        // 2. Add Quick Settings toggle
        this._quickIndicator = new HotspotQuickIndicator(this);
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._quickIndicator);

        // State polling
        this._pollId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            POLL_SECONDS,
            () => { this.syncAll(); return GLib.SOURCE_CONTINUE; }
        );

        this.syncAll();
    }

    async syncAll() {
        const status = readStatusFile();
        if (status) {
            this._trayButton?.updateState(true, status.clients, status);
            this._quickIndicator?.updateState(true, status.clients);
            return;
        }

        // Fallback: check iw dev
        try {
            const r = await execAsync(['iw', 'dev']);
            const up = r.ok && /\btype AP\b/.test(r.stdout);
            this._trayButton?.updateState(up, []);
            this._quickIndicator?.updateState(up, []);
        } catch (_e) {
            this._trayButton?.updateState(false, []);
            this._quickIndicator?.updateState(false, []);
        }
    }

    disable() {
        if (this._pollId) {
            GLib.source_remove(this._pollId);
            this._pollId = 0;
        }

        this._trayButton?.destroy();
        this._trayButton = null;

        this._quickIndicator?.destroy();
        this._quickIndicator = null;
    }
}
