# mbms-broadcast-tutorial

Launches a complete **LTE-based 5G Terrestrial Broadcast (FeMBMS / MBMS)**
reference deployment in one `tmux` session, one window per function, with
per-window logging. It is the LTE-broadcast analogue of
`5G-MAG/rt-mbs-examples`' `mbs-function-tutorial.sh`.

By default it runs the **software-radio (ZeroMQ)** end-to-end setup, so no SDR
hardware is required.

## What it starts (in dependency order)

```
Transmit:  srsepc (EPC/MME) ─▶ srsenb (eNB) ─▶ mbms-gw ─▶ bmsc (BM-SC)
                                   │ ZMQ I/Q (tcp://127.0.0.1:2000)
Receive:   modem  ◀──────────────┘   ─▶ client (mw) ─▶ application (web UI, :3000)
Control:   application-provider (portal, :8080)
```

| Window | Binary | Default port(s) |
| --- | --- | --- |
| EPC | `rt-mbms-tx/build/srsepc/src/srsepc` | S1AP 36412, Sm 2123, SBc bridge 2102 |
| eNB | `rt-mbms-tx/build/srsenb/src/srsenb` | control 2100 |
| MBMS-GW | `rt-mbms-gw/build/mbms-gw/mbms-gw` | control 2101, M1-U 2153 |
| BM-SC | `rt-mbms-bmsc/build/bmsc/bmsc` | xMB-C 8543 |
| Modem | `rt-mbms-modem/build/modem` | REST 3010 |
| Client | `rt-mbms-client/build/client` | REST 3020 |
| Application | `rt-mbms-application` (`node app.js`) | 3000 |
| Portal | `rt-mbms-application-provider` (`node --env-file=.env server.js`) | 8080 |

## Prerequisites

- `tmux`, `node`, and coreutils `stdbuf` on `PATH`.
- All seven components built (see each repo's README).
- For the ZeroMQ software-radio path, a SoapySDR `zmqrx` bridge that **you build
  yourself** — it is intentionally not shipped with this tutorial. See
  [ZeroMQ software radio](#zeromq-software-radio) below. Not needed for a real SDR.
- A complete, generic ZeroMQ config set already ships in `./conf/` — the only
  thing to create is the bmsc mTLS certs (one `openssl` block); see
  [`conf/README.md`](conf/README.md).
- `rt-mbms-application-provider/.env` with `AUTH_TOKEN` set (the portal refuses
  to start without it).

## Usage

Two ways to bring the whole chain up:

**A. Background launcher (simplest, no tmux) — good for a demo:**

```bash
./launch-all.sh          # start the whole chain in the background
./launch-all.sh --stop   # stop everything it started (incl. the root srsepc)
```

Each component runs backgrounded with its own log under
`~/.local/state/mbms-broadcast-tutorial/<Name>.log`. It authenticates sudo once
(for the EPC), clears a leftover `srsepc`, warns on already-bound ports, and
sets `SOAPY_SDR_PLUGIN_PATH` for the modem.

**B. tmux tutorial (one visible window per function)** — needs `tmux`
(`sudo apt install tmux`):

```bash
./mbms-broadcast-tutorial.sh          # launch all functions in tmux and attach
./mbms-broadcast-tutorial.sh --kill   # tear the session down (incl. the root srsepc)
```

Both share the same `conf/` and defaults. On launch each runs two preflight guards so re-runs stay clean:
- It stops a **leftover `srsepc` (EPC/MME)** first. `srsepc` runs as root, so a
  `tmux kill-session` can't stop it, and a stale instance is the usual cause of
  `bind(): Address already in use` on the S1-MME socket. `--kill` stops it too.
- It **warns** if any stack port (2100/2101/3000/3010/3020/8080/8543) is already
  bound by a leftover component, before launching.

Inside tmux: `Ctrl-b n/p` next/prev window, `Ctrl-b w` window list,
`Ctrl-b d` detach, `tmux attach -t mbms-broadcast` to re-attach. Logs are under
`~/.local/state/mbms-broadcast-tutorial/<Window>.log`.

## Configuration

Every path and config filename is a variable at the top of the script; override
by editing the CONFIG block or via the environment, e.g.:

```bash
CONF=/path/to/my/conf MW_IFACE=192.168.1.50 ./mbms-broadcast-tutorial.sh
```

### Privileges (sudo)

`srsepc` needs root (its SP-GW brings up a TUN interface and edits routing), so
its window runs under `sudo`. Following the reference tutorial, the script
authenticates **once** up front (`sudo -v`) and keeps the credential warm while
the windows launch; it never stores your password. Depending on your sudoers
`tty_tickets` setting, the EPC pane may prompt once in its own window — enter the
same password there.

The other components run without root by default. Enable `sudo` for them only
when needed, via environment toggles:

```bash
SUDO_ENB=sudo SUDO_MODEM=sudo ./mbms-broadcast-tutorial.sh   # real SDR
SUDO_GW=sudo   ./mbms-broadcast-tutorial.sh                  # mbms-gw sgi_mb TUN enabled
```

Notes:
- Windows stay open if a component exits, showing the error and its log path.

## ZeroMQ software radio

The default config runs without an SDR: the eNB transmits I/Q over ZeroMQ
(srsRAN's native `zmq` RF driver) and the modem receives it. The modem receives
through a **SoapySDR module that registers a `zmqrx` driver** (see
`conf/modem_zmqtest.conf`: `device_args = "driver=zmqrx,rx_port=tcp://127.0.0.1:2000"`),
which connects to the eNB's ZeroMQ transmitter and presents the samples as an SDR
receive device.

This bridge is **not shipped with the tutorial** — build (or supply) it yourself:

1. Install the dev packages: `sudo apt install libsoapysdr-dev libzmq3-dev`.
2. Provide a SoapySDR out-of-tree module that registers the `zmqrx` driver (a
   `SoapySDR::Registry("zmqrx", …)` device that reads I/Q from the eNB's ZeroMQ
   `rx_port`) and build it to `libzmqrxSupport.so`, e.g.:
   ```bash
   g++ -std=c++17 -shared -fPIC ZmqRxDevice.cpp -o libzmqrxSupport.so \
     $(pkg-config --cflags --libs SoapySDR libzmq)
   ```
3. Point the launcher at the directory holding `libzmqrxSupport.so`:
   ```bash
   SOAPY_ZMQ_DIR=/path/to/your/bridge ./mbms-broadcast-tutorial.sh
   # (or export SOAPY_SDR_PLUGIN_PATH; default is ~/soapy-zmq-bridge)
   ```
   The script exports `SOAPY_SDR_PLUGIN_PATH` for the Modem window; preflight
   warns if the module is missing.

**Prefer a real SDR?** Set the eNB `device_name`/`device_args` for your radio
(UHD / BladeRF / SoapySDR) in `conf/enb_baseline.conf`, drop the modem's `zmqrx`
`device_args` in `conf/modem_zmqtest.conf`, and you don't need this bridge at all.

## Full chain on one host (receive side in a network namespace)

On real hardware the transmitter and receiver are separate machines. On a single
host the eNB's M1-U receiver and the client's content receiver both want UDP
`:2153` and collide. To run the **whole chain on one box**, put the receive side
in its own network namespace with `receive-netns.sh` (needs sudo):

```bash
./launch-all.sh --transmit-only        # EPC + eNB + MBMS-GW + BM-SC (root netns)
sudo ./receive-netns.sh start          # modem + client + application in netns "mbms-rx"
```

The eNB transmits ZMQ on `tcp://*:2000`, and the namespace reaches it over a veth
(`10.80.0.1` root ⟷ `10.80.0.2` netns); the modem's ZMQ RX is pointed at
`10.80.0.1:2000` automatically. The receiver's multicast / `:2153` now live
inside `mbms-rx`, isolated from the eNB.

Watch the result from the host:

- **player UI: http://10.80.0.2:3000**  (the application, in the namespace)
- modem API `10.80.0.2:3010`, client API `10.80.0.2:3020`

Drive content as usual from the portal (`:8080`, transmit side): start
`demo-content/hls-http-proxy.js`, Load template, Activate. Tear down with:

```bash
sudo ./receive-netns.sh stop
./launch-all.sh --stop
```

Note: netns + veth needs root and can't be exercised in every environment, so if
a component doesn't come up first try, check its log in
`~/.local/state/mbms-broadcast-tutorial/` and the veth/routing with
`sudo ip netns exec mbms-rx ip addr`.
