# -*- coding: utf-8 -*-
# Affichage terminal de from-lynis-to-100 : panneau fixe en bas de l'écran
# (progression, étape, action en cours, score Lynis), journal qui défile au-dessus,
# bilan final avec ce qui n'a pas réussi. Hors terminal (CI, redirection) : texte simple.
from __future__ import annotations

DOCUMENTATION = """
    name: lynis100_tui
    type: stdout
    short_description: Affichage dynamique de from-lynis-to-100
    description:
      - Panneau de progression fixe (style watch) et journal lisible en français.
    requirements:
      - Terminal compatible ANSI (sinon affichage texte simple)
"""

import atexit
import os
import re
import shutil
import sys
import threading
import time

from ansible.plugins.callback import CallbackBase

# Étapes du rôle : fichier de tâches -> (titre, explication courte)
PHASES = {
    "questions.yml": ("Questions", "confirmation des changements critiques"),
    "site.yml": ("Préparation", "Python et collecte des informations système"),
    "00_preflight.yml": ("Prérequis", "vérification de la machine et sauvegardes"),
    "01_baseline.yml": ("Audit initial", "score Lynis de départ"),
    "02_packages.yml": ("Paquets", "installation des outils de sécurité"),
    "03_accounts.yml": ("Comptes", "mots de passe, expiration, umask"),
    "04_shell_coredump.yml": ("Shell", "déconnexion auto et core dumps"),
    "05_kernel.yml": ("Noyau", "paramètres sysctl et modules bloqués"),
    "06_mounts.yml": ("Montages", "options noexec / nosuid / hidepid"),
    "07_ssh_fail2ban.yml": ("SSH", "configuration SSH et fail2ban"),
    "08_firewall.yml": ("Pare-feu", "blocage des connexions entrantes"),
    "09_usb.yml": ("USB", "désactivation des périphériques USB"),
    "10_dns.yml": ("DNS", "deux serveurs DNS via un résolveur local"),
    "11_audit_integrity.yml": ("Intégrité", "auditd, AIDE, antivirus"),
    "12_updates_banners_grub.yml": ("Système", "mises à jour, bannières, GRUB"),
    "13_nginx.yml": ("nginx", "en-têtes de sécurité si nginx est présent"),
    "14_compilers.yml": ("Compilateurs", "retrait de gcc / binutils"),
    "15_exceptions.yml": ("Finitions", "exceptions Lynis documentées"),
    "16_ssh_port_switch.yml": ("Port SSH", "bascule du port avec retour arrière"),
    "17_final_audit.yml": ("Audit final", "score Lynis d'arrivée"),
    "main.yml": ("Handlers", "redémarrage des services modifiés"),
}
# Fichier de tâches -> tag pour rejouer l'étape seule après une correction manuelle
TAGS = {
    "02_packages.yml": "packages", "03_accounts.yml": "accounts", "04_shell_coredump.yml": "shell",
    "05_kernel.yml": "kernel", "06_mounts.yml": "mounts", "07_ssh_fail2ban.yml": "ssh",
    "08_firewall.yml": "firewall", "09_usb.yml": "usb", "10_dns.yml": "dns",
    "11_audit_integrity.yml": "integrity", "12_updates_banners_grub.yml": "grub",
    "13_nginx.yml": "nginx", "14_compilers.yml": "compilers", "15_exceptions.yml": "exceptions",
    "16_ssh_port_switch.yml": "ssh", "01_baseline.yml": "audit", "17_final_audit.yml": "audit",
}
TEST_ID = re.compile(r"\b([A-Z]{2,5}-[0-9]{4})\b")
SHELL_MODULES = {"command", "shell", "raw", "script", "ansible.builtin.command",
                 "ansible.builtin.shell", "ansible.builtin.raw", "ansible.builtin.script"}
FOOTER = 7
SPIN = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
ANSI = re.compile(r"\x1b\[[0-9;]*m")

C = {"g": "\x1b[32m", "y": "\x1b[33m", "r": "\x1b[31m", "c": "\x1b[36m",
     "b": "\x1b[1m", "d": "\x1b[2m", "0": "\x1b[0m"}


def bar(pct, width, color):
    pct = max(0.0, min(100.0, pct))
    full = int(width * pct / 100.0)
    return color + "█" * full + C["d"] + "░" * (width - full) + C["0"]


def fmt_time(sec):
    sec = int(sec)
    return "%02d:%02d:%02d" % (sec // 3600, (sec % 3600) // 60, sec % 60)


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "stdout"
    CALLBACK_NAME = "lynis100_tui"

    def __init__(self):
        super().__init__()
        self.tty = sys.stdout.isatty() and os.environ.get("TERM", "dumb") != "dumb"
        self.lock = threading.RLock()
        self.start = time.time()
        self.total = 0
        self.done = 0
        self.phase_key = None
        self.phase_order = []
        self.phase_state = {}
        self.current = ""
        self.current_kind = ""
        self.task_start = time.time()
        self.counts = {"ok": 0, "changed": 0, "skipped": 0, "failed": 0}
        self.failures = []
        self.fail_phases = []
        self.nonzero = []
        self.score_before = None
        self.score_after = None
        self.partial = []
        self.warnings = []
        self.final_msg = []
        self.host = ""
        self.region = False
        self.paused = False
        self.rows = 0
        self.stop = threading.Event()
        self.thread = None
        atexit.register(self._leave_region)

    # ------------------------------------------------------------- écran ---
    def _w(self, s):
        sys.stdout.write(s)
        sys.stdout.flush()

    def _size(self):
        sz = shutil.get_terminal_size((100, 30))
        return max(40, sz.columns), max(FOOTER + 5, sz.lines)

    def _enter_region(self):
        if not self.tty or self.region:
            return
        cols, rows = self._size()
        self.rows = rows
        self._w("\r\n" * FOOTER)
        self._w("\x1b[1;%dr\x1b[%d;1H" % (rows - FOOTER, rows - FOOTER))
        self.region = True
        self._draw()

    def _leave_region(self):
        if not self.region:
            return
        cols, rows = self._size()
        self._w("\x1b7")
        for i in range(FOOTER):
            self._w("\x1b[%d;1H\x1b[2K" % (rows - FOOTER + 1 + i))
        self._w("\x1b8\x1b[r\x1b[%d;1H" % (rows - FOOTER))
        self.region = False

    def _fit(self, text, cols):
        plain = ANSI.sub("", text)
        if len(plain) <= cols:
            return text
        return plain[: cols - 1] + "…"

    def _footer_lines(self, cols):
        elapsed = fmt_time(time.time() - self.start)
        bw = max(10, min(40, cols - 40))
        pct = 100.0 * self.done / self.total if self.total else 0.0
        n = len(self.phase_order)
        title, expl = PHASES.get(self.phase_key, (self.phase_key or "-", ""))
        spin = SPIN[int(time.time() * 8) % len(SPIN)]
        kind = {"sh": C["y"] + "Commande sh" + C["0"],
                "ansible": C["c"] + "Ansible" + C["0"],
                "pause": C["y"] + "Question" + C["0"]}.get(self.current_kind, "")
        cur = "%s %s : %s" % (spin, kind, self.current) if self.current else "-"
        if self.current:
            cur += C["d"] + "  (%ds)" % (time.time() - self.task_start) + C["0"]
        if self.score_after is not None:
            lyn = "%s %3s %%  %s(avant %s %%)%s" % (bar(float(self.score_after), bw, C["g"]),
                                                     self.score_after, C["d"], self.score_before, C["0"])
        elif self.score_before is not None:
            lyn = "%s %3s %%  %s(score de départ, mesuré à nouveau à la fin)%s" % (
                bar(float(self.score_before), bw, C["y"]), self.score_before, C["d"], C["0"])
        else:
            lyn = C["d"] + "pas encore mesuré" + C["0"]
        c = self.counts
        bil = "%s✔ %d ok%s  %s↻ %d modifiés%s  %s⤼ %d ignorés%s  %s✖ %d échecs%s" % (
            C["g"], c["ok"], C["0"], C["y"], c["changed"], C["0"], C["d"], c["skipped"], C["0"],
            C["r"] if c["failed"] else C["d"], c["failed"], C["0"])
        head = "─── from-lynis-to-100 ── %s ── %s " % (self.host or "…", elapsed)
        return [
            C["b"] + head + "─" * max(0, cols - len(head)) + C["0"],
            " Progression  %s %3d %%  %s(%d/%d tâches)%s" % (bar(pct, bw, C["c"]), pct, C["d"], self.done, self.total, C["0"]),
            " Étape        %s%s%s %s— %s%s  %s[%d]%s" % (C["b"], title, C["0"], C["d"], expl, C["0"], C["d"], n, C["0"]),
            " En cours     " + cur,
            " Lynis        " + lyn,
            " Bilan        " + bil,
            C["d"] + "─" * cols + C["0"],
        ]

    def _draw(self):
        with self.lock:
            if not self.region:
                return
            cols, rows = self._size()
            if rows != self.rows:
                self.rows = rows
                self._w("\x1b[1;%dr\x1b[%d;1H" % (rows - FOOTER, rows - FOOTER))
            out = ["\x1b7"]
            for i, line in enumerate(self._footer_lines(cols)):
                out.append("\x1b[%d;1H\x1b[2K%s" % (rows - FOOTER + 1 + i, self._fit(line, cols)))
            out.append("\x1b8")
            self._w("".join(out))

    def _loop(self):
        while not self.stop.wait(0.25):
            if not self.paused:
                self._draw()

    def log(self, text, color=""):
        with self.lock:
            cols, _ = self._size()
            line = self._fit(text, cols) if self.region else text
            if not self.tty:
                line = ANSI.sub("", line)
                color = ""
            self._w("%s%s%s%s" % (color, line, C["0"] if color else "", "\r\n" if self.tty else "\n"))
            self._draw()

    # ---------------------------------------------------------- utilitaires ---
    @staticmethod
    def _count(blocks):
        n = 0
        for b in blocks:
            for t in list(getattr(b, "block", []) or []) + list(getattr(b, "always", []) or []):
                if hasattr(t, "block"):
                    n += CallbackModule._count([t])
                elif getattr(t, "action", "") not in ("meta", "ansible.builtin.meta"):
                    n += 1
        return n

    def _phase_of(self, task):
        path = task.get_path() or ""
        fname = os.path.basename(path.split(":")[0])
        if "/handlers/" in path:
            return "main.yml"
        return fname if fname in PHASES else (fname or "site.yml")

    @staticmethod
    def _short(task):
        name = task.get_name().strip()
        return name.split(" | ", 1)[1] if " | " in name else name

    def _set_phase(self, key):
        if key == self.phase_key:
            return
        if self.phase_key and self.phase_state.get(self.phase_key) == "run":
            self.phase_state[self.phase_key] = "ok"
        self.phase_key = key
        if key not in self.phase_state:
            self.phase_order.append(key)
        self.phase_state[key] = "run"
        title, expl = PHASES.get(key, (key, ""))
        self.log("")
        self.log("▶ [%02d] %s — %s" % (len(self.phase_order), title, expl), C["b"] + C["c"])

    # ------------------------------------------------------------ événements ---
    def v2_playbook_on_play_start(self, play):
        try:
            self.total += self._count(play.compile())
        except Exception:  # pylint: disable=broad-except
            pass
        self.log("━━ %s" % play.get_name().strip(), C["b"])

    def v2_playbook_on_task_start(self, task, is_conditional):
        with self.lock:
            action = task.action or ""
            if action not in ("pause", "ansible.builtin.pause"):
                self._enter_region()
            self._set_phase(self._phase_of(task))
            self.current = self._short(task)
            self.task_start = time.time()
            if action in ("pause", "ansible.builtin.pause"):
                self.current_kind = "pause"
                self.paused = True
                self._leave_region()
            else:
                self.paused = False
                self._enter_region()
                self.current_kind = "sh" if action in SHELL_MODULES else "ansible"
            self._draw()

    def v2_playbook_on_handler_task_start(self, task):
        self.v2_playbook_on_task_start(task, False)

    def _finish(self, result, state):
        with self.lock:
            self.host = self.host or result._host.get_name()
            task = result._task
            res = result._result
            action = task.action or ""
            name = self._short(task)
            facts = res.get("ansible_facts", {}) if isinstance(res, dict) else {}
            if "lynis100_score_before" in facts:
                self.score_before = facts["lynis100_score_before"]
            if "lynis100_score_after" in facts:
                self.animate(facts["lynis100_score_after"])
            if "lynis100_partial_tests" in facts:
                self.partial = list(facts["lynis100_partial_tests"] or [])
            if "lynis100_warnings" in facts:
                self.warnings = list(facts["lynis100_warnings"] or [])
            dur = time.time() - self.task_start
            if action in SHELL_MODULES and state != "skipped":
                rc = res.get("rc", 0)
                self.log("  ⚙ Commande sh : %s" % name, C["y"])
                if state == "failed" or (rc not in (0, None) and not res.get("failed")):
                    self.log("    ↳ terminée avec le code %s (%.1f s)%s" % (
                        rc, dur, "" if state == "failed" else " — non bloquant, prévu par le rôle"), C["y"])
                    if state != "failed":
                        self.nonzero.append("%s (code %s)" % (name, rc))
                else:
                    self.log("    ↳ ✔ fonctionne (%.1f s) — retour à Ansible" % dur, C["g"])
            elif state == "changed":
                self.log("  ↻ %s" % name, C["y"])
            if action in ("debug", "ansible.builtin.debug") and state != "skipped":
                msg = res.get("msg")
                lines = msg if isinstance(msg, list) else [msg] if msg else []
                if task.get_name().endswith("Audit final | Résultat"):
                    self.final_msg = [str(x) for x in lines]
                else:
                    for x in lines:
                        if not isinstance(x, (dict, list)):
                            self.log("  ℹ %s" % x, C["d"])
            self.done = min(self.done + 1, self.total) if self.total else self.done + 1
            self.current = ""
            self._draw()

    def v2_runner_on_ok(self, result):
        changed = result._result.get("changed", False)
        self.counts["changed" if changed else "ok"] += 1
        self._finish(result, "changed" if changed else "ok")
        if result._task.action in ("pause", "ansible.builtin.pause"):
            self.paused = False

    def v2_runner_on_skipped(self, result):
        self.counts["skipped"] += 1
        self._finish(result, "skipped")

    def v2_runner_on_failed(self, result, ignore_errors=False):
        res = result._result
        msg = res.get("msg") or res.get("stderr") or res.get("stdout") or "erreur"
        msg = str(msg).strip().splitlines()[0] if str(msg).strip() else "erreur"
        name = self._short(result._task)
        self._finish(result, "failed")
        if ignore_errors:
            self.counts["ok"] += 1
            self.log("  ⚠ %s : %s (ignoré)" % (name, msg), C["y"])
        else:
            self.counts["failed"] += 1
            self.failures.append("%s : %s" % (name, msg))
            self.fail_phases.append(self.phase_key)
            if self.phase_key:
                self.phase_state[self.phase_key] = "fail"
            self.log("  ✖ %s : %s" % (name, msg), C["r"] + C["b"])

    def v2_runner_on_unreachable(self, result):
        self.counts["failed"] += 1
        msg = str(result._result.get("msg", "injoignable")).strip()
        self.failures.append("%s : %s" % (result._host.get_name(), msg))
        self.log("  ✖ Machine injoignable : %s" % msg, C["r"] + C["b"])
        self._finish(result, "failed")

    def v2_runner_item_on_failed(self, result):
        item = self._get_item_label(result._result)
        msg = str(result._result.get("msg") or result._result.get("stderr") or "").strip()
        self.log("    ✖ élément %s en échec : %s" % (item, msg.splitlines()[-1] if msg else "erreur"), C["r"])

    def v2_playbook_on_start(self, playbook):
        if self.tty:
            self.thread = threading.Thread(target=self._loop, daemon=True)
            self.thread.start()

    def animate(self, after):
        """Fait monter la barre Lynis du score de départ au score final."""
        try:
            start = int(self.score_before or 0)
            end = int(after)
        except (TypeError, ValueError):
            self.score_after = after
            return
        if self.tty and self.region and end > start:
            for v in range(start, end + 1):
                self.score_after = v
                self._draw()
                time.sleep(min(0.05, 2.0 / (end - start + 1)))
        self.score_after = end

    def v2_playbook_on_stats(self, stats):
        self.stop.set()
        if self.phase_key and self.phase_state.get(self.phase_key) == "run":
            self.phase_state[self.phase_key] = "ok"
        self.done = self.total
        self._draw()
        self._leave_region()
        cols, _ = self._size()
        bw = max(10, min(40, cols - 30))
        p = self.log
        p("")
        p("═" * min(cols, 70), C["b"])
        p(" RÉSULTAT from-lynis-to-100  (durée %s)" % fmt_time(time.time() - self.start), C["b"])
        p("═" * min(cols, 70), C["b"])
        for k in self.phase_order:
            st = self.phase_state.get(k)
            icon, col = ("✔", C["g"]) if st == "ok" else ("✖", C["r"])
            p(" %s %s" % (icon, PHASES.get(k, (k,))[0]), col)
        p("")
        if self.score_before is not None:
            p(" Lynis avant  %s %s %%" % (bar(float(self.score_before), bw, C["y"]), self.score_before))
        if self.score_after is not None:
            col = C["g"] if int(self.score_after) >= 100 else C["y"]
            p(" Lynis après  %s %s %%" % (bar(float(self.score_after), bw, col), self.score_after))
        for line in self.final_msg:
            if line.startswith(("SSH", "Redémarrage")):
                p(" " + line)
        p("")
        problems = self.failures or self.partial or self.warnings
        if not problems:
            if self.score_after is not None and int(self.score_after) >= 100:
                p(" ✔ Tout est passé : Lynis 100 %.", C["g"] + C["b"])
            else:
                p(" ✔ Aucune erreur Ansible.", C["g"])
        if self.failures:
            p(" ✖ Ce qui n'a pas réussi :", C["r"] + C["b"])
            for f in self.failures:
                p("   - " + f, C["r"])
        if self.partial:
            p(" ✖ Tests Lynis non validés (points manquants) :", C["y"] + C["b"])
            for f in self.partial:
                p("   - " + f, C["y"])
        if self.warnings:
            p(" ⚠ Avertissements Lynis :", C["y"] + C["b"])
            for f in self.warnings:
                p("   - " + f, C["y"])
        if self.nonzero:
            p(" ℹ Commandes sh avec code non nul, sans conséquence (vérifications) : %d" % len(self.nonzero), C["d"])
        # Ce que la personne devra sans doute faire à la main
        todo = []
        for f, ph in zip(self.failures, self.fail_phases):
            tag = TAGS.get(ph)
            todo.append(("Corriger : " + f,
                         "ansible-playbook site.yml --tags " + tag if tag else "ansible-playbook site.yml"))
        ids = []
        for t in self.partial + self.warnings:
            for i in TEST_ID.findall(t):
                if i not in ids:
                    ids.append(i)
        for i in ids:
            todo.append(("%s : lynis show details %s" % (i, i), "https://cisofy.com/lynis/controls/%s/" % i))
        if todo:
            p("")
            p(" ✍ À faire à la main :", C["b"])
            for n, (t, aide) in enumerate(todo, 1):
                p("   %d. %s" % (n, t))
                p("      → " + aide, C["d"])
            p("   Puis vérifier : lynis audit system --quick", C["d"])
        p("")
        for h in sorted(stats.processed.keys()):
            s = stats.summarize(h)
            p(" %s : ok=%d modifiés=%d ignorés=%d échecs=%d injoignable=%d" % (
                h, s["ok"], s["changed"], s["skipped"], s["failures"], s["unreachable"]))
