"""Non-destructive regression tests. All disk/network commands use fixtures or stubs."""
import gzip
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "dd.sh"
BASH = shutil.which("bash")
SH = shutil.which("dash") or "/bin/sh"


class ReinstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dd-test-")
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, TEST_ROOT=str(self.root), LC_ALL="C")

    def tearDown(self):
        self.temp.cleanup()

    def bash(self, text, *, ok=True, stdin=None, env=None):
        result = subprocess.run(
            [BASH, "-c", 'source "$1"; defaults; ' + text, "test", str(SCRIPT)],
            env=env or self.env, input=stdin, text=True, capture_output=True, timeout=20,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def payloads(self, extra=""):
        result = self.bash('''
            set -e
            workdir=$TEST_ROOT
            mkdir -p "$workdir/root/dd"
            net_mac=52:54:00:12:34:56; iface=ens3
            ip_addr=192.0.2.10; ip_mask=255.255.255.255; prefix=32
            ip_gate=192.0.2.1; ip_dns='8.8.8.8 1.1.1.1'
            selected_mirror=http://deb.debian.org/debian
            password_hash='$6$literal$test'
        ''' + extra + '\nwrite_payloads\n')
        return self.root / "root/dd"

    def test_source_and_help_are_passive(self):
        result = self.bash('printf loaded')
        self.assertEqual(result.stdout, "loaded")
        result = subprocess.run([BASH, str(SCRIPT), "--help"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("raw.gz", result.stdout)

    def test_removed_loader_and_missing_values(self):
        for args in (["--loader"], ["-p"], ["--ip-mask"], ["--unknown"]):
            result = subprocess.run([BASH, str(SCRIPT), *args], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("apt-get", result.stdout)
        result = self.bash('parse_args -dd ""', ok=False)
        self.assertNotEqual(result.returncode, 0)

    def test_literal_password_arguments_and_hashes(self):
        for password in ["abc def", r"a\b", "-n", "a;'\"$(touch BAD)*?", "$6$salt$hash", "密码 123"]:
            env = dict(self.env, TEST_PASSWORD=password)
            result = self.bash('''
                set -e
                parse_args -p "$TEST_PASSWORD"
                [[ $password == "$TEST_PASSWORD" ]]
                make_password_hash
                [[ -z $password ]]
                printf '%s' "$password_hash"
            ''', env=env)
            self.assertTrue(result.stdout.startswith("$6$"))
            salt = result.stdout.split("$")[2]
            expected = subprocess.run(
                ["openssl", "passwd", "-6", "-salt", salt, "-stdin"],
                input=password + "\n", text=True, capture_output=True, check=True,
            ).stdout.strip()
            self.assertEqual(result.stdout, expected)
        self.assertFalse((REPO / "BAD").exists())

    def test_port_boundaries(self):
        for value, expected in [("22", "22"), ("00022", "22"), ("65535", "65535")]:
            result = self.bash('normalize_port "$TEST_PORT"', env=dict(self.env, TEST_PORT=value))
            self.assertEqual(result.stdout.strip(), expected)
        for value in ["", "0", "65536", "-1", "22;id", "999999999999999999999"]:
            result = self.bash('normalize_port "$TEST_PORT"', env=dict(self.env, TEST_PORT=value), ok=False)
            self.assertNotEqual(result.returncode, 0)

    def test_masks_and_offlink_gateway(self):
        for bits, mask in [(0, "0.0.0.0"), (24, "255.255.255.0"), (31, "255.255.255.254"), (32, "255.255.255.255")]:
            result = self.bash(f'prefix_mask {bits}; mask_prefix {mask}')
            self.assertEqual(result.stdout.splitlines(), [mask, str(bits)])
        result = self.bash('mask_prefix 255.0.255.0', ok=False)
        self.assertNotEqual(result.returncode, 0)
        result = self.bash('ip_addr=192.0.2.10; ip_mask=255.255.255.255; ip_gate=198.51.100.1; validate_network; printf "%s %s" "$prefix" "$offlink"')
        self.assertEqual(result.stdout, "32 1")

    def test_conflicting_dhcp_rejected(self):
        result = self.bash('parse_args --dhcp --ip-addr 192.0.2.10; normalize_options', ok=False)
        self.assertNotEqual(result.returncode, 0)

    def test_network_probe_uses_source_address_on_same_interface(self):
        result = self.bash('''
            set -e
            ip() {
                if [[ $1 == -4 ]]; then printf '1.1.1.1 via 198.51.100.1 dev ens3 src 192.0.2.10\\n'
                else printf '2: ens3 inet 10.0.0.2/24 scope global ens3\\n2: ens3 inet 192.0.2.10/32 scope global ens3\\n'
                fi
            }
            cat() { if [[ $1 == /sys/class/net/ens3/address ]]; then printf '52:54:00:12:34:56\\n'; else command cat "$@"; fi; }
            detect_network
            printf '%s %s %s %s' "$iface" "$ip_addr" "$prefix" "$ip_gate"
        ''')
        self.assertEqual(result.stdout, "ens3 192.0.2.10 32 198.51.100.1")

    def test_static_installer_routes_and_dns(self):
        data = self.payloads()
        net = self.root / "net/ens3"
        net.mkdir(parents=True)
        (net / "address").write_text("52:54:00:12:34:56\n")
        bins = self.root / "bin"
        bins.mkdir()
        for name, code in [("modprobe", "exit 0"), ("ip", 'printf "%s\\n" "$*" >> "$TEST_ROOT/ip.log"')]:
            path = bins / name
            path.write_text("#!/bin/sh\n" + code + "\n")
            path.chmod(0o700)
        text = (data / "network.sh").read_text().replace("/sys/class/net", str(self.root / "net"))
        text = text.replace("/etc/resolv.conf", str(self.root / "resolv.conf"))
        env = dict(self.env, PATH=str(bins) + os.pathsep + os.environ["PATH"])
        result = subprocess.run([SH, "-c", text, "test", str(data)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = (self.root / "ip.log").read_text().splitlines()
        self.assertIn("addr add 192.0.2.10/32 dev ens3", lines)
        self.assertLess(lines.index("route add 192.0.2.1/32 dev ens3"), lines.index("route add default via 192.0.2.1 dev ens3"))
        self.assertEqual((self.root / "resolv.conf").read_text(), "nameserver 8.8.8.8\nnameserver 1.1.1.1\n")

    def test_dhcp_and_static_preseed_are_separate(self):
        self.payloads()
        for mode in ["dhcp", "static"]:
            self.bash(f'workdir=$TEST_ROOT; network_mode={mode}; ip_addr=192.0.2.4; ip_mask=255.255.255.0; '
                      'ip_gate=192.0.2.1; prefix=24; selected_mirror=http://mirror/debian; password_hash=HASH; generate_preseed')
            text = (self.root / "root/preseed.cfg").read_text()
            self.assertNotIn("netcfg/enable boolean false", text)
            self.assertNotIn("network-only", text)
            self.assertEqual("netcfg/disable_autoconfig boolean true" in text, mode == "static")
            self.assertEqual("netcfg/get_nameservers string 8.8.8.8" in text, mode == "static")
            self.assertNotIn("restore.sh", text)
            self.assertNotIn("ture", text)
            self.assertIn("choose_recipe select atomic", text)
            self.assertIn("root-login boolean true", text)

    def test_dd_preseed_cannot_fall_into_normal_partitioning(self):
        self.payloads()
        self.bash('workdir=$TEST_ROOT; image_url=http://image/disk.raw.gz; selected_mirror=http://mirror/debian; generate_preseed')
        text = (self.root / "root/preseed.cfg").read_text()
        self.assertIn("partman/early_command string /bin/sh /dd/early.sh", text)
        self.assertNotIn("partman-auto/", text)
        self.assertNotIn("anna-install", text)
        self.assertNotIn("preseed/early_command", text)

    def test_offlink_hook_runs_after_original_netcfg(self):
        self.payloads()
        hook = self.root / 'root/var/lib/dpkg/info/netcfg.postinst'
        hook.parent.mkdir(parents=True)
        original = '#!/bin/sh\nexec netcfg\n'
        hook.write_text(original)
        hook.chmod(0o755)
        self.bash('workdir=$TEST_ROOT; offlink=1; selected_mirror=http://mirror/debian; generate_preseed')
        preseed = (self.root / 'root/preseed.cfg').read_text()
        self.assertIn('netcfg/enable boolean false', preseed)
        self.assertNotIn('preseed/early_command', preseed)
        self.assertEqual(Path(str(hook) + '.before-dd').read_text(), original)
        self.assertLess(hook.read_text().index('"$0.before-dd" "$@" || exit $?'), hook.read_text().index('exec /bin/sh /dd/early.sh network-only'))

    def test_mirror_default_and_root_url(self):
        result = self.bash('release=debian; choose_mirror; printf "%s" "$mirror"', stdin="y\n\n")
        self.assertTrue(result.stdout.endswith("http://mirrors.aliyun.com/debian"))
        self.payloads()
        self.bash('workdir=$TEST_ROOT; selected_mirror=http://mirror; generate_preseed')
        self.assertIn("mirror/http/directory string /\n", (self.root / "root/preseed.cfg").read_text())

    def test_ftp_repository_fields(self):
        self.payloads()
        self.bash('workdir=$TEST_ROOT; selected_mirror=ftp://mirror/debian; generate_preseed')
        text = (self.root / "root/preseed.cfg").read_text()
        self.assertIn("mirror/protocol string ftp", text)
        self.assertIn("mirror/ftp/hostname string mirror", text)
        self.assertNotIn("mirror/http/hostname", text)

    def test_https_mirror_keeps_protocol_through_selection_and_preseed(self):
        result = self.bash('''
            set -e
            workdir=$TEST_ROOT
            arch=amd64; dist=bullseye; mirror=https://example.test/debian
            download() { printf x > "$2"; }
            file() { printf 'Linux kernel'; }
            unpack_initrd() {
                mkdir -p "$workdir/root/bin" "$workdir/root/var/lib/dpkg"
                printf 'Package: wget-udeb\\n' > "$workdir/root/var/lib/dpkg/status"
                printf 'mirror/https/hostname' > "$workdir/root/bin/choose-mirror"
            }
            fetch_installer; generate_preseed
            printf '%s' "$selected_mirror"
        ''')
        self.assertEqual(result.stdout, 'https://example.test/debian')
        self.assertIn('mirror/https/hostname string example.test', (self.root / 'root/preseed.cfg').read_text())

    def test_legacy_download_and_menu_targets(self):
        self.assertEqual((REPO / 'dd_fixed.sh').read_bytes(), SCRIPT.read_bytes())
        numbers = self.bash('image_presets').stdout.splitlines()
        self.assertEqual([int(row.split('|')[0]) for row in numbers], list(range(9, 37)))
        result = self.bash('set -e; uname() { printf x86_64; }; choose_preset 25; normalize_options; describe_target')
        self.assertIn('25) Win7x64', result.stdout)
        self.assertIn('类型=windows', result.stdout)
        self.assertNotIn('?id=', result.stdout)
        result = self.bash('image_url="https://user:secret@example.test/disk.gz?token=secret#part"; describe_target')
        self.assertIn('https://example.test/disk.gz', result.stdout)
        self.assertNotIn('secret', result.stdout)

    def test_nonempty_confirmation_cancels(self):
        result = self.bash('confirm_target', stdin='n\n', ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('已取消重装', result.stderr)
        self.bash('confirm_target', stdin='\n')
        self.bash('assume_yes=1; confirm_target', stdin='')

    def test_command_does_not_delete_other_cron_jobs_or_retry(self):
        data = self.payloads('command_b64=$(printf "exit 7\\n" | base64)')
        configure = (data / "configure.sh").read_text()
        script = configure.split("<<'COMMAND'\n", 1)[1].split("\nCOMMAND\n", 1)[0]
        jobs = self.root / "cron"
        jobs.mkdir()
        (jobs / "dd-reinstall").write_text("own job")
        (jobs / "other").write_text("other job")
        script = script.replace("/etc/cron.d/dd-reinstall", str(jobs / "dd-reinstall"))
        script = script.replace("/root/dd-reinstall/", str(data) + "/")
        result = subprocess.run([SH, "-c", script], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((jobs / "dd-reinstall").exists())
        self.assertTrue((jobs / "other").exists())
        self.assertTrue((data / "user-command.sh").exists())

    def test_windows_payload_is_opt_in_and_mac_bound(self):
        data = self.payloads('image_kind=windows; network_mode=dhcp; rdp_port=33890')
        raw = (data / "net.bat").read_bytes()
        self.assertIn(b"52-54-00-12-34-56", raw)
        self.assertIn(b"getmac /v /fo csv /nh", raw)
        self.assertIn(b"diskpart /s", raw)
        self.assertIn(b"source=dhcp\r\n", raw)
        self.assertNotIn(b"\n", raw.replace(b"\r\n", b""))
        self.assertNotIn(b"\r", raw.replace(b"\r\n", b""))
        self.assertIn(rb'\Wds\rdpwd\Tds\tcp" /v PortNumber /t REG_DWORD /d 33890 /f', raw)
        self.assertIn(b"if not defined DD_CONFIGURED exit /b 1", raw)

    def test_payloads_are_posix_syntax_and_do_not_embed_input(self):
        dangerous = "http://mirror/image.raw.gz?a=';touch_BAD&x=1"
        env = dict(self.env, TEST_URL=dangerous)
        self.bash('workdir=$TEST_ROOT; mkdir -p "$workdir/root/dd"; image_url=$TEST_URL; write_payloads', env=env)
        payload_dir = self.root / "root/dd"
        self.assertEqual((payload_dir / "image_url").read_text().strip(), dangerous)
        for path in payload_dir.glob("*.sh"):
            result = subprocess.run([SH, "-n", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, str(path) + result.stderr)
            self.assertNotIn(dangerous, path.read_text())

    def test_target_ssh_config_and_rhel_network(self):
        data = self.payloads('network_mode=static; image_kind=rhel')
        target = self.root / "target"
        (target / "etc/ssh").mkdir(parents=True)
        (target / "etc/sysconfig/network-scripts").mkdir(parents=True)
        (target / "etc/ssh/sshd_config").write_text(
            "Port 22\nUseDNS yes\nHostKey /etc/ssh/custom_host_key\n"
            "Subsystem sftp /usr/lib/openssh/sftp-server\nMatch User root\n PasswordAuthentication no\n"
            "Match User backup\n PasswordAuthentication no\n"
            "Match User root Address 192.0.2.0/24\n PermitRootLogin no\n"
        )
        dropins = target / "etc/ssh/sshd_config.d"
        dropins.mkdir()
        (dropins / "policy.conf").write_text("Port=22\nMatch Group staff\n PasswordAuthentication no\n")
        (target / "etc/sysconfig/network-scripts/ifcfg-eth0").write_text("BOOTPROTO=dhcp\n")
        cmd = '''DD_LIBRARY_ONLY=1; . "$1/configure.sh" "$1"; write_ssh_config "$2" 2222; configure_network "$2" rhel'''
        result = subprocess.run([SH, "-c", cmd, "test", str(data), str(target)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = (target / "etc/ssh/sshd_config.dd-new").read_text()
        self.assertIn("Port 2222\n", config)
        self.assertIn("PasswordAuthentication yes", config)
        self.assertIn("Match User root\n    PasswordAuthentication yes", config)
        self.assertIn("Match User backup\n PasswordAuthentication no", config)
        self.assertIn("Match User root Address 192.0.2.0/24\n PermitRootLogin no", config)
        self.assertEqual((dropins / "policy.conf").read_text(), "Match Group staff\n PasswordAuthentication no\n")
        self.assertIn("UseDNS yes", config)
        self.assertIn("HostKey /etc/ssh/custom_host_key", config)
        self.assertIn("Subsystem sftp /usr/lib/openssh/sftp-server", config)
        scripts = target / "etc/sysconfig/network-scripts"
        self.assertIn("PREFIX=32", (scripts / "ifcfg-ddnet0").read_text())
        self.assertIn("192.0.2.1/32 dev ddnet0", (scripts / "route-ddnet0").read_text())
        self.assertTrue((scripts / "dd-backup/ifcfg-eth0").exists())

    def test_rhel_dhcp_does_not_keep_static_route(self):
        data = self.payloads('network_mode=dhcp; image_kind=rhel')
        target = self.root / "target"
        scripts = target / "etc/sysconfig/network-scripts"
        scripts.mkdir(parents=True)
        (scripts / "route-ddnet0").write_text("old route\n")
        cmd = 'DD_LIBRARY_ONLY=1; . "$1/configure.sh" "$1"; configure_network "$2" rhel'
        result = subprocess.run([SH, "-c", cmd, "test", str(data), str(target)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BOOTPROTO=dhcp", (scripts / "ifcfg-ddnet0").read_text())
        self.assertNotIn("IPADDR", (scripts / "ifcfg-ddnet0").read_text())
        self.assertFalse((scripts / "route-ddnet0").exists())

    def test_kickstart_applies_port_and_password(self):
        self.payloads()
        self.bash('workdir=$TEST_ROOT; release=centos; dist=6.10; ssh_port=2222; selected_mirror=http://vault; password_hash=HASH; generate_kickstart')
        text = (self.root / "root/ks.cfg").read_text()
        self.assertIn("rootpw --iscrypted HASH", text)
        self.assertIn("firewall --enabled --port=2222:tcp", text)
        self.assertIn("configure.sh", text)
        self.assertIn("\nunsupported_hardware\n", text)
        self.assertIn("\ntext\n", text)
        self.bash('workdir=$TEST_ROOT; dist=6.3; installer_vnc=1; selected_mirror=https://vault; generate_kickstart')
        text = (self.root / 'root/ks.cfg').read_text()
        self.assertIn('url --url="https://vault/6.3/os/x86_64/"', text)
        self.assertNotIn("unsupported_hardware", text)
        self.assertNotIn("\ntext\n", text)
        self.assertRegex(text, r'\nvnc --password=[A-Za-z0-9+/]{8}\n')

    def test_no_disk_returns_error_not_dev_directory(self):
        result = self.bash('lsblk() { :; }; get_disk', ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_grub_entry_does_not_parse_or_change_existing_entries(self):
        old = "set default=2\nmenuentry 'old' {\n if [ x = x ]; then\n echo nested\n fi\n}\n"
        (self.root / "grub.cfg").write_text(old)
        self.bash('grub_cfg=$TEST_ROOT/grub.cfg; write_grub_candidate "$TEST_ROOT/new.cfg" UUID /dd/vmlinuz /dd/initrd.img /dd/grubenv dd-test "auto=true"')
        text = (self.root / "new.cfg").read_text()
        self.assertTrue(text.startswith(old))
        self.assertIn("if save_env --file=($dd_boot)/dd/grubenv dd_reinstall; then", text)
        self.assertIn("set default='dd-test'", text)
        self.assertNotIn("saved_entry/#saved_entry", text)

    def test_boot_failure_restores_current_backup(self):
        (self.root / "grub.cfg").write_text("modified")
        (self.root / "before").write_text("current original")
        (self.root / "work").mkdir()
        self.bash('''
            grub_cfg=$TEST_ROOT/grub.cfg; grub_backup=$TEST_ROOT/before
            grub_changed=1; workdir=$TEST_ROOT/work
            cleanup
        ''')
        self.assertEqual((self.root / "grub.cfg").read_text(), "current original")
        self.assertFalse((self.root / "work").exists())

    def test_embedded_preseed_is_not_loaded_again_as_file(self):
        result = self.bash('boot_options')
        self.assertNotIn('preseed/file=', result.stdout)
        self.assertNotIn('lowmem=+2', result.stdout)

    def test_original_defaults_and_package_group_are_preserved(self):
        self.payloads()
        self.bash('workdir=$TEST_ROOT; selected_mirror=http://mirror/debian; generate_preseed')
        preseed = (self.root / 'root/preseed.cfg').read_text()
        self.assertIn('time/zone string US/Eastern', preseed)
        self.assertIn('tasksel tasksel/first multiselect\n', preseed)
        self.assertIn('debian-installer/allow_unauthenticated boolean true', preseed)
        self.bash('workdir=$TEST_ROOT; selected_mirror=http://mirror/centos; generate_kickstart')
        kickstart = (self.root / 'root/ks.cfg').read_text()
        self.assertIn('timezone --utc Asia/Hong_Kong', kickstart)
        self.assertIn('\n@base\n', kickstart)

    def test_original_interface_option_and_compatibility_aliases(self):
        result = self.bash('parse_args -i eth0 -m --manual -ssl; printf "%s|%s" "$installer_iface" "$iface"')
        self.assertEqual(result.stdout, 'eth0|')
        # Replace the interpreter before calling the wrapper; no child reinstall runs.
        result = self.bash('bash() { printf "%s\\n" "$@"; }; InstallNET_Main -d 12 --dhcp')
        self.assertEqual(result.stdout.splitlines(), [str(SCRIPT), '-d', '12', '--dhcp'])

    def test_legacy_boot_paths_and_original_entry_indices(self):
        for old_path, new_path in [('/boot/vmlinuz-old', '/boot/dd-test/vmlinuz'), ('/vmlinuz-old', '/dd-test/vmlinuz')]:
            original = ('default=0\ntimeout=1\ntitle Old Linux\n root (hd0,0)\n'
                        f' kernel {old_path} old-option\n initrd /initrd-old\n'
                        'title Recovery\n root (hd0,0)\n kernel /recovery\n')
            (self.root / 'grub.conf').write_text(original)
            self.bash('grub_cfg=$TEST_ROOT/grub.conf; install_dir=/boot/dd-test; write_legacy_candidate "$TEST_ROOT/new.conf" auto=true')
            text = (self.root / 'new.conf').read_text()
            self.assertTrue(text.startswith('default 2\nfallback 0\ntimeout 3\n'))
            self.assertNotIn('default=0', text)
            self.assertNotIn('timeout=1', text)
            self.assertLess(text.index('title Old Linux'), text.index('title Recovery'))
            self.assertIn(f'kernel {new_path} auto=true', text)
            self.assertIn('root (hd0,0)', text)

    def test_grub_persistent_mode_does_not_require_environment_writes(self):
        (self.root / 'grub.cfg').write_text("menuentry 'old' { echo old; }\n")
        self.bash('grub_cfg=$TEST_ROOT/grub.cfg; boot_once=0; write_grub_candidate "$TEST_ROOT/new.cfg" UUID /dd/kernel /dd/initrd "" dd-test auto=true')
        text = (self.root / 'new.cfg').read_text()
        self.assertIn("set default='dd-test'", text)
        self.assertNotIn('save_env', text)
        self.assertNotIn('load_env', text)

    def test_old_version_mappings_and_centos_i386_paths(self):
        for args, expected in [('-d 7', 'wheezy'), ('-d 12.1 -v x64', 'bookworm'), ('-d BOOKWORM -v X86', 'bookworm'), ('-d 9', 'stretch'), ('-u 14.04', 'trusty')]:
            result = self.bash('uname() { printf x86_64; }; parse_args ' + args + '; normalize_options; printf "%s" "$dist"')
            self.assertEqual(result.stdout, expected)
        result = self.bash('uname() { printf x86_64; }; parse_args -c 6.9 -v 32; normalize_options; installer_paths; printf "%s" "$kernel_path"')
        self.assertEqual(result.stdout, '6.9/os/i386/isolinux/vmlinuz')

    def test_cn_default_does_not_require_a_real_network_request(self):
        result = self.bash('curl() { printf \'{"country":"CN"}\'; }; detect_cn_default')
        self.assertEqual(result.stdout, 'y')

    def test_grub_environment_exists_before_mkrelpath(self):
        # All paths and tools are fixtures; do not touch the host /boot.
        (self.root / 'work').mkdir()
        (self.root / 'work/initrd.img').write_bytes(b'initrd')
        (self.root / 'work/vmlinuz').write_bytes(b'kernel')
        (self.root / 'grub.cfg').write_text("menuentry 'original' { echo original; }\n")
        self.bash('''
            set -e
            workdir=$TEST_ROOT/work; grub_cfg=$TEST_ROOT/grub.cfg
            mktemp() {
                if [[ $1 == -d ]]; then mkdir "$TEST_ROOT/boot"; printf '%s' "$TEST_ROOT/boot"
                else touch "$TEST_ROOT/candidate"; printf '%s' "$TEST_ROOT/candidate"; fi
            }
            probe() { printf UUID; }
            relpath() { [[ -f $1 ]] || return 8; printf '/@/boot/install/%s' "${1##*/}"; }
            envtool() {
                case $2 in
                    create) : > "$1" ;;
                    set) printf '%s\\n' "$3" > "$1" ;;
                    list) cat "$1" ;;
                esac
            }
            check() { return 0; }
            chmod() { :; }; chown() { :; }; sync() { :; }
            grub_probe=probe; grub_relpath=relpath; grub_editenv=envtool; grub_check=check
            commit_boot
        ''')
        self.assertTrue((self.root / 'boot/grubenv').exists())
        self.assertIn("'/@/boot/install/vmlinuz'", (self.root / 'grub.cfg').read_text())
        self.assertIn("menuentry 'original'", (self.root / 'boot/grub.cfg.before-dd').read_text())

    def test_resolver_copy_does_not_follow_absolute_target_symlink(self):
        data = self.payloads()
        text = (data / 'restore.sh').read_text()
        function = 'copy_resolver() {' + text.split('copy_resolver() {', 1)[1].split('\n}', 1)[0] + '\n}'
        outside = self.root / 'outside'
        outside.write_text('must stay unchanged')
        source = self.root / 'resolver-source'
        source.write_text('nameserver 192.0.2.1\n')
        dest = self.root / 'resolver-dest'
        dest.symlink_to(outside)
        result = subprocess.run(
            [SH, '-c', function + '\ncopy_resolver "$1" "$2"', 'test', str(source), str(dest)],
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(dest.is_symlink())
        self.assertEqual(dest.read_text(), source.read_text())
        self.assertEqual(outside.read_text(), 'must stay unchanged')

    def test_iptables_rule_is_inserted_only_in_filter_table(self):
        data = self.payloads()
        rules = self.root / 'iptables'
        rules.write_text('*nat\n:PREROUTING ACCEPT [0:0]\n-A PREROUTING -j ACCEPT\nCOMMIT\n'
                         '*filter\n:INPUT DROP [0:0]\n-A INPUT -j REJECT\nCOMMIT\n')
        code = 'DD_LIBRARY_ONLY=1; . "$1/configure.sh" "$1"; write_iptables_rule "$2" 2222'
        result = subprocess.run([SH, '-c', code, 'test', str(data), str(rules)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        before_filter, filter_table = rules.read_text().split('*filter', 1)
        self.assertNotIn('--dport', before_filter)
        self.assertLess(filter_table.index('--dport 2222'), filter_table.index('-A INPUT -j REJECT'))

    def test_kickstart_stops_on_preparation_failure(self):
        self.payloads()
        self.bash('workdir=$TEST_ROOT; selected_mirror=http://mirror; generate_kickstart')
        post = (self.root / 'root/ks.cfg').read_text().split('%post', 1)[1]
        self.assertLess(post.index('trap '), post.index('mkdir -p /root/dd-reinstall'))
        self.assertIn('set -e -o pipefail', post)
        self.assertIn('trap - EXIT\n%end', post)

    def run_restore(self, body, download_rc=0, fail_writer=False, disk_use=None):
        data = self.payloads('image_url=http://image/disk.raw.gz; image_kind=raw')
        fixture = self.root / "image.gz"
        fixture.write_bytes(body)
        disk = self.root / "disk"
        disk.write_bytes(b"ORIGINAL")
        bins = self.root / "bin"
        bins.mkdir()
        mounts = self.root / "mounts"
        mounts.write_text('41 30 8:1 / /mnt rw - ext4 /dev/disk1 rw\n' if disk_use == 'mounted' else '')
        swaps = self.root / "swaps"
        swaps.write_text("Filename Type Size Used Priority\n")
        sysdisk = self.root / "sys/disk"
        for node, devnum in [(sysdisk, '8:0'), (sysdisk / 'disk1', '8:1')]:
            (node / 'holders').mkdir(parents=True)
            (node / 'dev').write_text(devnum + '\n')
        (sysdisk / 'disk1/partition').write_text('1\n')
        if disk_use == 'holder':
            (sysdisk / 'disk1/holders/dm-0').touch()
        if disk_use == 'md':
            (sysdisk / 'md').mkdir()
        commands = {
            "list-devices": 'case "$1" in disk) printf "%s\\n" "$TEST_ROOT/disk" ;; esac',
            "wget": f'cat "$TEST_ROOT/image.gz"; exit {download_rc}',
            "blockdev": 'echo reread >> "$TEST_ROOT/events"',
            "blkid": "exit 0",
            "swapoff": "exit 0",
            "umount": "exit 1",
            "udevadm": "exit 0",
            "sync": "exit 0",
            "reboot": 'echo reboot >> "$TEST_ROOT/events"',
        }
        if fail_writer:
            commands["dd"] = f'case "$*" in *of={disk.resolve()}*) exit 9 ;; *) exec /bin/dd "$@" ;; esac'
        for name, code in commands.items():
            path = bins / name
            path.write_text("#!/bin/sh\n" + code + "\n")
            path.chmod(0o700)
        script = (data / "restore.sh").read_text()
        script = script.replace("data=/dd", "data=" + shlex.quote(str(data)))
        script = script.replace('[ -b "$disk" ]', '[ -f "$disk" ]')
        script = script.replace("/sys/class/block", str(self.root / "sys"))
        script = script.replace("/proc/self/mountinfo", str(mounts))
        script = script.replace("/proc/swaps", str(swaps))
        script = script.replace("/tmp/dd-", str(self.root / "dd-"))
        script = script.replace("/sbin/reboot", str(bins / "reboot"))
        env = dict(self.env, PATH=str(bins) + os.pathsep + os.environ["PATH"])
        result = subprocess.run([SH, "-c", script], env=env, text=True, capture_output=True, timeout=20)
        events = (self.root / "events").read_text() if (self.root / "events").exists() else ""
        return result, disk.read_bytes(), events

    def test_active_partition_holder_stops_before_disk_write(self):
        result, disk, events = self.run_restore(gzip.compress(b'A' * 1024), disk_use='holder')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(disk, b'ORIGINAL')
        self.assertEqual(events, '')

    def test_busy_mount_stops_before_disk_write(self):
        result, disk, events = self.run_restore(gzip.compress(b'A' * 1024), disk_use='mounted')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(disk, b'ORIGINAL')
        self.assertEqual(events, '')

    def test_raid_device_returned_as_disk_is_rejected(self):
        result, disk, events = self.run_restore(gzip.compress(b'A' * 1024), disk_use='md')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(disk, b'ORIGINAL')
        self.assertEqual(events, '')

    def test_stream_write_success(self):
        image = b"RAW IMAGE" * 200
        result, disk, events = self.run_restore(gzip.compress(image))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(disk, image)
        self.assertIn("reboot", events)

    def test_download_failure_never_reboots(self):
        result, _, events = self.run_restore(gzip.compress(b"A" * 1024), download_rc=7)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("reboot", events)

    def test_bad_gzip_never_reboots(self):
        result, _, events = self.run_restore(gzip.compress(b"A" * 1024)[:-8])
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("reboot", events)

    def test_tiny_image_never_changes_disk(self):
        result, disk, events = self.run_restore(gzip.compress(b"tiny"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(disk, b"ORIGINAL")
        self.assertNotIn("reboot", events)

    def test_writer_failure_never_reboots(self):
        result, _, events = self.run_restore(gzip.compress(b"A" * 1024), fail_writer=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("reboot", events)


if __name__ == "__main__":
    unittest.main()
