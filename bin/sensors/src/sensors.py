import sys
import json
import xml.etree.ElementTree as ET
import tkinter as tk
from tkinter import ttk, messagebox
from pathlib import Path
import os

SENSOR_FILE_EXT = ".lua"
SIM_FILE_ALIASES = {
    "PID#": "pid_profile",
    "RTE#": "rate_profile",
    "BatP": "battery_profile",
    "Bat%": "fuel",
    "Vbat": "voltage",
    "Hspd": "rpm",
    "TescT": "temp_esc",
    "TmcuT": "temp_mcu",
    "Thr%": "throttle_percent",
    "Cel#": "cell_count",
    "Alt": "altitude",
}


class SensorApp:

    def __init__(self, root, config_path=None):
        self.root = root
        self.root.title("Sensor Editor")

        # The script layout is:
        #   GITREPO/bin/sensors/sensors.exe
        #   or GITREPO/bin/sensors/src/sensors.py
        # Sensors live under:
        #   GITREPO/simulator/<target>/scripts/rfsuite/sim/sensors

        self.repo_root = self._discover_repo_root()
        self.simulator_root = self.repo_root / "simulator"

        # Auto-discover all simulator sensor output folders.
        # Supports both legacy multi-target layout and edgetx-ui-framework layout.
        self.dest_paths = self._discover_sensor_output_dirs()

        # Load icon (prefer src/sensors.ico, fall back to exe icon in frozen mode)
        possible_icons = []
        if getattr(sys, 'frozen', False):
            possible_icons.append(self.repo_root / "bin" / "sensors" / "src" / "sensors.ico")
            possible_icons.append(Path(sys.executable).with_name("sensors.ico"))
        else:
            possible_icons.append(Path(__file__).parent / "sensors.ico")
            possible_icons.append(self.repo_root / "bin" / "sensors" / "src" / "sensors.ico")
        for icon in possible_icons:
            if icon.exists():
                try:
                    self.root.iconbitmap(default=icon)
                    break
                except Exception as e:
                    print(f"[DEBUG] Could not set icon: {e}")
        else:
            if getattr(sys, 'frozen', False):
                try:
                    self.root.iconbitmap(default=sys.executable)
                except Exception:
                    pass

        self.controls = {}
        self.load_config()

    def _discover_repo_root(self):
        if getattr(sys, "frozen", False):
            base_dir = Path(sys.executable).resolve().parent
        else:
            base_dir = Path(__file__).resolve().parent

        candidates = [base_dir, *base_dir.parents]
        for candidate in candidates:
            if (candidate / "simulator").exists() and (candidate / "bin").exists():
                return candidate

        raise FileNotFoundError(
            f"Could not locate repository root from: {base_dir}"
        )

    def _discover_sensor_output_dirs(self):
        """
        Discover simulator sensor output directories.

                Supported layouts (rfsuite-only):
                    1) simulator/<target>/scripts/rfsuite/sim/sensors
                    2) simulator/SCRIPTS/RFSUITE/core/sim/sensors
                    3) simulator/SCRIPTS/RFSUITE/user/sim/sensors

        Returns a list of Path objects pointing to the final '.../sim/sensors' dirs.
        """
        simulator_root = self.simulator_root

        if not simulator_root.exists():
            raise FileNotFoundError(
                f"Simulator root not found at expected path: {simulator_root}"
            )

        dest_paths = []

        # Layout 2: edgetx-ui-framework style (single simulator tree)
        direct_sensor_dir = simulator_root / "SCRIPTS" / "RFSUITE" / "core" / "sim" / "sensors"
        if direct_sensor_dir.exists():
            print(f"[DEBUG] Found direct sensors dir: {direct_sensor_dir}")
            dest_paths.append(direct_sensor_dir)

        user_sensor_dir = simulator_root / "SCRIPTS" / "RFSUITE" / "user" / "sim" / "sensors"
        if user_sensor_dir.exists():
            print(f"[DEBUG] Found user sensors dir: {user_sensor_dir}")
            dest_paths.append(user_sensor_dir)

        # Layout 1: multi-target style (one folder per target)
        for target_dir in simulator_root.iterdir():
            if not target_dir.is_dir():
                continue

            scripts_dir = target_dir / "scripts"
            sensors_dir = scripts_dir / "rfsuite" / "sim" / "sensors"

            if sensors_dir.exists():
                print(f"[DEBUG] Found sensors dir: {sensors_dir}")
                dest_paths.append(sensors_dir)

        if not dest_paths:
            # Create default paths on-demand. This keeps startup robust in a fresh simulator directory.
            direct_sensor_dir.mkdir(parents=True, exist_ok=True)
            print(f"[DEBUG] Created default sensors dir: {direct_sensor_dir}")
            dest_paths.append(direct_sensor_dir)

        # Deduplicate while preserving order
        uniq = []
        seen = set()
        for p in dest_paths:
            key = str(p)
            if key not in seen:
                seen.add(key)
                uniq.append(p)

        return uniq

    def load_config(self):
        possible_xml = [
            Path.cwd() / 'sensors.xml',
            Path.cwd().parent / 'sensors.xml'
        ]
        for xml_path in possible_xml:
            if xml_path.exists():
                break
        else:
            raise FileNotFoundError(f"Missing XML config; looked in: {possible_xml}")

        tree = ET.parse(xml_path)
        for group in tree.getroot().findall('Group'):
            frame = ttk.LabelFrame(self.root, text=group.get('name'))
            frame.pack(fill='x', padx=10, pady=5)
            for sensor in group.findall('Sensor'):
                self.add_sensor_control(frame, sensor)

        ttk.Button(self.root, text='Save All', command=self.save_all).pack(pady=10)

    def add_sensor_control(self, parent, sensor_elem):
        name = sensor_elem.get('name')
        label = sensor_elem.get('label', name)
        sensor_type = sensor_elem.get('type', 'number')
        multiplier = float(sensor_elem.get('multiplier', 1))
        unit = sensor_elem.get('unit', '')
        default = float(sensor_elem.get('default', 0))

        row = ttk.Frame(parent)
        row.pack(fill='x', padx=5, pady=2)
        ttk.Label(row, text=label, width=20).pack(side='left')

        value_var = tk.StringVar(value=str(default))

        if sensor_type == 'range':
            min_val = float(sensor_elem.get('min', 0))
            max_val = float(sensor_elem.get('max', 100))
            rounding = sensor_elem.get('round') == 'true'
            control = ttk.Scale(
                row,
                from_=min_val,
                to=max_val,
                orient='horizontal',
                command=lambda v, var=value_var, rnd=rounding: var.set(
                    f"{int(float(v))}" if rnd else f"{float(v):.2f}"))
            control.set(default)
            control.pack(side='left', fill='x', expand=True)
            ttk.Entry(row, textvariable=value_var, width=6).pack(side='left', padx=5)
        elif sensor_type == 'bool':
            control = ttk.Checkbutton(row, variable=value_var, onvalue='1', offvalue='0')
            value_var.set('1' if default else '0')
            control.pack(side='left')
        elif sensor_type == 'select':
            control = ttk.Combobox(row, textvariable=value_var, state='readonly')
            options = [opt.get('label')
                       for opt in sensor_elem.findall('Option')]
            values = [opt.get('value') for opt in sensor_elem.findall('Option')]
            control['values'] = options
            value_map = dict(zip(options, values))
            reverse_map = dict(zip(values, options))
            display = reverse_map.get(str(default), options[0] if options else '')
            value_var.set(display)
            control.pack(side='left')
            self.controls[name] = (value_var, multiplier, sensor_type, value_map)
            return
        else:
            rounding = sensor_elem.get('round') == 'true'
            if rounding:
                value_var.set(str(int(default)))
            ttk.Entry(row, textvariable=value_var).pack(side='left', fill='x', expand=True)

        if unit:
            ttk.Label(row, text=unit).pack(side='left')

        self.controls[name] = (value_var, multiplier, sensor_type, None)

    def save_all(self):
        possible_xml = [
            Path.cwd() / 'sensors.xml',
            Path.cwd().parent / 'sensors.xml'
        ]
        for xml_path in possible_xml:
            if xml_path.exists():
                break
        else:
            raise FileNotFoundError(f"Missing XML config; looked in: {possible_xml}")

        tree = ET.parse(xml_path)
        rand_map = {sensor.get('name'): sensor.get('rand')
                    for group in tree.getroot().findall('Group')
                    for sensor in group.findall('Sensor')}

        def build_sensor_file_names(sensor_name):
            names = [sensor_name]
            alias_name = SIM_FILE_ALIASES.get(sensor_name)
            if alias_name and alias_name not in names:
                names.append(alias_name)
            if sensor_name == "Curr":
                names.append("Curr+")
            return names

        for name, (var, mult, sensor_type, val_map) in self.controls.items():
            raw = var.get()
            try:
                if sensor_type == 'select' and val_map:
                    raw = val_map.get(raw, '0')
                numeric = float(raw) * mult

                rand_attr = rand_map.get(name)

                file_names = build_sensor_file_names(name)
                for out_dir in self.dest_paths:
                    out_dir.mkdir(parents=True, exist_ok=True)
                    for file_name in file_names:
                        out_path = out_dir / (file_name + SENSOR_FILE_EXT)
                        print(f"[DEBUG] Updating sensor '{name}' at path: {out_path}")
                        try:
                            with open(out_path, 'w') as f:
                                if rand_attr:
                                    delta = numeric * float(rand_attr) / 100.0
                                    low = int(numeric - delta)
                                    high = int(numeric + delta)
                                    f.write(f"return math.random({low}, {high})")
                                else:
                                    f.write(f"return {numeric}")
                        except Exception as e:
                            print(f"[DEBUG] Failed to write {out_path}: {e}")
                            messagebox.showerror("Error", f"Failed to write {out_path}: {e}")
            except Exception as e:
                print(f"Error saving {name}: {e}")
                messagebox.showerror("Error", f"Error saving {name}: {e}")


if __name__ == '__main__':
    root = tk.Tk()
    app = SensorApp(root)
    root.mainloop()
