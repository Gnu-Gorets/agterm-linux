"""Two real GTK apps exercise remote pages and companions over the shared SSH protocol."""

import json
import os
import shlex
import subprocess

from atspi_smoke import CTL, ROOT, launch, press_return, raw_control_json, stop, type_x11_text, wait_for


def verify_remote_v0391(env, state):
    origin_state, viewer_state, tools = [os.path.join(state, name) for name in ("origin", "viewer", "remote-bin")]
    for directory in (origin_state, viewer_state, tools):
        os.makedirs(directory)
    fixture = os.path.join(state, "login-shell.so")
    subprocess.run(["cc", "-shared", "-fPIC", "-o", fixture,
                    os.path.join(ROOT, "tests/login_shell_zsh_fixture.c"), "-ldl"], check=True)
    with open(os.path.join(origin_state, "settings.json"), "w", encoding="utf-8") as file:
        json.dump({"restoreMode": "live", "closeGraceUndoEnabled": False}, file)
    ssh = os.path.join(tools, "ssh")
    with open(ssh, "w", encoding="utf-8") as file:
        file.write('#!/bin/sh\n[ "$1" = "-G" ] && { printf "serveraliveinterval 0\\n"; exit 0; }\n'
                   'for argument do remote=$argument; done\n'
                   'export AGTERM_STATE_DIR="$AGTERM_TEST_ORIGIN_STATE"\n'
                   'export AGTERM_CONTROL_SOCKET="$AGTERM_TEST_ORIGIN_SOCKET"\n'
                   'exec /bin/sh -c "$remote"\n')
    os.chmod(ssh, 0o755)
    os.symlink(CTL, os.path.join(tools, "agtermctl"))
    origin_env = dict(env, AGTERM_STATE_DIR=origin_state, AGTERM_CONTROL_SOCKET=os.path.join(origin_state, "agterm.sock"),
                      AGTERM_APP_ID=env["AGTERM_APP_ID"] + ".origin", LD_PRELOAD=fixture,
                      AGTERM_ZMX_PATH=os.path.join(ROOT, "vendor/zmx/zmx"))
    viewer_env = dict(env, AGTERM_STATE_DIR=viewer_state, AGTERM_CONTROL_SOCKET=os.path.join(viewer_state, "agterm.sock"),
                      AGTERM_APP_ID=env["AGTERM_APP_ID"] + ".viewer", AGTERM_TEST_ORIGIN_STATE=origin_state,
                      AGTERM_TEST_ORIGIN_SOCKET=origin_env["AGTERM_CONTROL_SOCKET"], PATH=tools + ":" + env["PATH"])
    origin_process = viewer_process = None

    def request(environment, command, target=None, args=None):
        response = raw_control_json(environment, {"cmd": command, "target": target, "args": args or {}}, timeout=45)
        assert response["ok"], response
        return response.get("result", {})

    def rows(environment):
        return [row for workspace in request(environment, "tree")["tree"]["workspaces"] for row in workspace["sessions"]]

    def row(environment, identity):
        return next((row for row in rows(environment) if row["id"] == identity), None)

    try:
        origin_process, _ = launch(origin_env)
        offered = wait_for(lambda: request(origin_env, "zmx.tree")["remote"].get("sessions"), "origin has no live session")
        origin = offered[0]["id"]
        request(origin_env, "session.companion.new", origin, {"name": "Keep parent alive", "noSelect": True})
        viewer_process, _ = launch(viewer_env)
        viewer = request(viewer_env, "zmx.attach", origin, {"host": "local-test"})["id"]
        wait_for(lambda: row(viewer_env, viewer).get("presentation", {}).get("state") == "connected",
                 "viewer presentation did not connect", timeout=20)

        pages = os.path.join(origin_state, "pages")
        os.makedirs(pages)
        with open(os.path.join(pages, "payload.txt"), "w", encoding="utf-8") as file:
            file.write("x" * (512 * 1024))
        with open(os.path.join(pages, "app.js"), "w", encoding="utf-8") as file:
            file.write('Promise.all([fetch("payload.txt").then(r=>r.text()),'
                       'agterm.request("session.rename",{args:{name:"Remote bridge reached origin"}})])'
                       '.then(([text])=>document.title="remote-asset:"+text.length)'
                       '.catch(error=>document.title="failure:"+error.message);')
        html = os.path.join(pages, "index.html")
        with open(html, "w", encoding="utf-8") as file:
            file.write('<!doctype html><title>Remote loading</title><script src="app.js"></script>')
        opened = request(origin_env, "session.overlay.open", origin,
                         {"html": html, "cwd": pages, "javascript": True, "sizePercent": 75})

        def page():
            return next(iter(row(viewer_env, viewer).get("htmlOverlays", [])), {})

        wait_for(lambda: page().get("title") == "remote-asset:524288", "remote assets/bridge did not load: " + str(page()), timeout=25)
        assert row(origin_env, origin)["name"] == "Remote bridge reached origin"
        wait_for(lambda: next(iter(row(origin_env, origin).get("htmlOverlays", [])), {}).get("state") == "loaded",
                 "origin did not receive page-state read-back")
        local_page = page()["id"]
        request(origin_env, "session.overlay.hide", origin)
        wait_for(lambda: row(viewer_env, viewer).get("hiddenOverlays") == ["session"], "remote hide did not reach viewer")
        request(origin_env, "session.overlay.show", origin)
        wait_for(lambda: not row(viewer_env, viewer).get("hiddenOverlays"), "remote show did not reach viewer")
        assert page()["id"] == local_page, "hide/show recreated the remote page"
        request(origin_env, "session.overlay.resize", origin, {"sizePercent": 50})
        wait_for(lambda: row(viewer_env, viewer).get("overlaySizePercent") == 50, "remote resize did not reach viewer")
        request(origin_env, "session.overlay.close", origin)
        wait_for(lambda: not page(), "origin close did not release the replica page")
        print("OK: remote assets, bridge, hide/show, resize, and close", flush=True)

        terminal = request(viewer_env, "session.companion.new", viewer, {"name": "Remote child", "noSelect": True})
        assert terminal["parent"] == viewer and row(viewer_env, terminal["id"])["parent"] == viewer
        origin_child = next(item for item in rows(origin_env) if item["name"] == "Remote child")
        assert origin_child["parent"] == origin
        duplicate = request(viewer_env, "session.companion.duplicate", viewer, {"noSelect": True})
        assert duplicate["parent"] == viewer

        companion = request(viewer_env, "session.companion.page", viewer,
                            {"html": html, "cwd": pages, "javascript": True, "follow": True})
        companion_id = companion["id"]
        wait_for(lambda: next(iter(row(viewer_env, companion_id).get("htmlOverlays", [])), {}).get("title") == "remote-asset:524288",
                 "remote page companion did not load", timeout=25)
        origin_page = next(item for item in rows(origin_env) if item.get("content") == "page")
        request(viewer_env, "session.close", companion_id)
        assert row(origin_env, origin_page["id"]), "closing the viewer ended the origin's page companion"
        reattached = request(viewer_env, "zmx.attach", origin_page["id"], {"host": "local-test"})["id"]
        wait_for(lambda: row(viewer_env, reattached).get("htmlOverlays", [{}])[0].get("state") == "loaded",
                 "page companion could not be reattached")
        request(origin_env, "session.close", origin_page["id"])
        wait_for(lambda: row(viewer_env, reattached) is None, "origin page close left its viewer row alive", timeout=20)

        # The parent's last shell exits while companions keep the session alive; both attached viewers recover.
        pid_file = os.path.join(origin_state, "shell.pid")

        def shell_pid():
            try:
                with open(pid_file, encoding="utf-8") as file:
                    return int(file.read())
            except (OSError, ValueError):
                return None

        request(origin_env, "session.lead", origin, {"pane": "left"})
        wait_for(lambda: row(origin_env, origin)["surfaces"][0].get("lead") == "leader", "origin did not take the lead")
        request(origin_env, "session.type", origin, {"text": "echo $$ > " + shlex.quote(pid_file) + "\r"})
        old_pid = wait_for(shell_pid, "origin shell did not answer")
        request(origin_env, "session.type", origin, {"text": "exit\r"})
        wait_for(lambda: any(entry.get("sessionID") == origin and entry.get("pane") == "left"
                            and entry.get("leaderPID") not in (None, old_pid)
                            for entry in request(origin_env, "zmx.list")["zmx"]["entries"]),
                 "parent daemon did not publish its replacement shell")
        wait_for(lambda: row(origin_env, origin) and row(origin_env, origin)["realized"], "parent shell did not respawn")
        wait_for(lambda: row(viewer_env, viewer)["surfaces"][0].get("lead") == "leader", "viewer did not reclaim the respawned pane")
        request(viewer_env, "session.select", viewer)
        type_x11_text("echo $$ > " + shlex.quote(pid_file) + "; echo respawn-recovered", viewer_process.pid)
        press_return(viewer_process.pid)

        def replaced_pid():
            return shell_pid() not in (None, old_pid)

        wait_for(replaced_pid, "parent shell PID did not change")
        wait_for(lambda: "respawn-recovered" in request(viewer_env, "session.text", viewer)["text"],
                 "attached terminal did not recover after parent respawn", timeout=25)
        print("OK: remote page assets/bridge/state, terminal/page companions, independent page lifetime, and parent respawn")
    except AssertionError:
        if origin_process is not None:
            print("Origin final rows:", [{k: v for k, v in item.items() if k != "foreground"} for item in rows(origin_env)], flush=True)
            print("Origin zmx:", request(origin_env, "zmx.list"), flush=True)
        if viewer_process is not None:
            print("Viewer final rows:", [{k: v for k, v in item.items() if k != "foreground"} for item in rows(viewer_env)], flush=True)
        raise
    finally:
        if viewer_process is not None:
            stop(viewer_process)
        if origin_process is not None:
            stop(origin_process)
