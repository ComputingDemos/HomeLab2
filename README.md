# Cybersecurity homelab: Zeek + Arkime + Splunk Universal Forwarder endpoints

This repository replaces the earlier custom-Ubuntu UF startup implementation with **Splunk's official Universal Forwarder image**. Both `src` and `dst` are independently addressed **Linux UF containers** that can generate and receive traffic, and forward their own lab logs to Splunk Enterprise. The original gateway, Zeek, OpenSearch, and automated Arkime configuration are retained.

**Deployment status:** All files were statically checked (YAML parsing, script syntax, configuration paths). **Docker image builds and complete runtime behavior have not been tested on your Ubuntu VM.** Test once before distributing to students.

## Architecture

| Service | Address(es) | Function |
| --- | --- | --- |
| `src` | `10.10.1.10` | Official UF with ping, iproute, Ncat; generates traffic and forwards logs |
| `dst` | `10.10.2.10` | Official UF with the same tools; receives traffic and forwards logs |
| `gw` | `10.10.1.1`, `10.10.2.1` | Routed choke point for src ↔ dst traffic |
| `splunk` | `10.10.1.30`, `10.10.2.30`, `10.10.3.30` | Splunk Enterprise web interface (8000) and UF receiver (9997) |
| `zeek` | `10.10.3.10` | Offline PCAP to logs |
| `arkime-capture` | `10.10.3.20` | Offline PCAP indexing |
| `arkime-viewer` | `10.10.3.21` | Session investigation, port 8005 |
| `opensearch` | `10.10.3.40` | Arkime metadata database |

`route-src` and `route-dst` are **temporary routing jobs**, not separate network endpoints. They share the respective UF container's network namespace to install static routes through `gw`; `Exited (0)` is normal. `arkime-init` is another expected one-time `Exited (0)` job. These jobs let the official Splunk image start without replacing its entrypoint.

The destination-side address for the indexer is local to each subnet, so forwarding on TCP 9997 **does not traverse the inter-endpoint choke point**. Source-to-destination lab traffic does. Zeek and Arkime currently analyze **saved PCAP files**; continuous live sensors and automatic PCAP import are not included.

## Included files

```
compose.yaml
Dockerfile.lab
Dockerfile.uf
setup.sh
verify.sh
.gitignore
splunk-app/default/inputs.conf
splunk-app/default/props.conf
uf-apps/src/default/inputs.conf
uf-apps/src/default/outputs.conf
uf-apps/dst/default/inputs.conf
uf-apps/dst/default/outputs.conf
```

`Dockerfile.uf` uses `splunk/universalforwarder:10.4.4`, installs `iproute`, `iputils`, `nmap-ncat`, `procps-ng` with `microdnf`, and preserves the official entrypoint. The official Red Hat UBI-based image is **not Ubuntu**. `nmap-ncat` provides `ncat`, **not the full `nmap` scanner**. For example, the exercise uses `ncat -z` rather than `nmap -sT`.

## 1. Prepare a new Ubuntu VM

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2 openssl tcpdump
sudo systemctl enable --now docker
printf 'vm.max_map_count=262144\n' | sudo tee /etc/sysctl.d/99-homelab.conf
sudo sysctl --system
```

The `vm.max_map_count` setting is needed for OpenSearch and persists across reboot. Ideally allocate at least 16 GB RAM and 4 vCPUs for the combined lab.

## 2. Replace an existing lab safely

**If you have the old Compose + Splunk overlay:**

```bash
cd ~/homelab
sudo docker compose -f compose.yaml -f compose.splunk.yaml down --remove-orphans
```

This stops the old deployment but preserves named volumes. Back up your old `compose.yaml` before extracting this archive. Do **not** run `compose.splunk.yaml` with the new configuration. The replacement `compose.yaml` includes Splunk already.

For a **genuinely clean lab only**, use `down -v --remove-orphans` instead of `down`. **Warning: `-v` permanently deletes Compose-managed Arkime, OpenSearch, Splunk, and UF state, including indexed sessions and stored PCAPs.** It does not delete bind-mounted host files such as `pcaps/` or `zeek-logs/`. If you keep the existing Splunk volumes, its previous administrator password remains active even when `.env` changes.

From Ubuntu, extract and copy the downloaded archive into the original lab directory:

```bash
mkdir -p ~/homelab /tmp/homelab-bundle
unzip -o ~/Downloads/homelab_uf_nodes.zip -d /tmp/homelab-bundle
cp -a /tmp/homelab-bundle/homelab_uf_nodes/. ~/homelab/
```

This archive contains a parent directory named `homelab_uf_nodes`. The `Dockerfile.lab` is the small Ubuntu gateway/routing utility image; the `Dockerfile.uf` builds the endpoint images.

## 3. Initialize credentials and folders

After reading and accepting the applicable Splunk license and general terms, execute:

```bash
cd ~/homelab
bash setup.sh
sudo docker compose config --quiet
```

`setup.sh` generates strong `SPLUNK_PASSWORD` and `UF_ADMIN_PASSWORD` credentials in `.env` **only if `.env` does not already exist**. It also creates directories used for traffic, Zeek, and endpoint logs. `config --quiet` checks the Compose configuration without launching it. `.env` and lab data are Git-ignored.

## 4. Deploy

```bash
sudo docker compose up -d --build
sudo docker compose ps -a
```

Allow time for Splunk and OpenSearch initialization. `arkime-init`, `route-src`, and `route-dst` should show `Exited (0)`. Other services should be running. The first image build needs internet access.

**Important:** Official Splunk startup may take several minutes on the initial run. Do not override the UF entrypoint and do not run `splunk start` inside `src` or `dst` as a separate manual startup procedure.

## 5. Verify network, UF processes, and log ingestion

```bash
bash verify.sh
```

The script checks both static routes, gateway connectivity, both `splunkd` processes, both indexer receiving connections, and OpenSearch, then creates a test log event **inside each UF container**. To repeat individual checks:

```bash
sudo docker compose exec src ip route get 10.10.2.10
sudo docker compose exec dst ip route get 10.10.1.10
sudo docker compose exec src ping -c 3 10.10.2.10
sudo docker compose exec src pgrep -a splunkd
sudo docker compose exec dst pgrep -a splunkd
```

If a UF container has been recreated *without restarting its routing job*, reapply both routes:

```bash
sudo docker compose up -d --force-recreate route-src route-dst
```

Splunk Enterprise web login from a browser **inside Ubuntu**: `http://10.10.3.30:8000`; user `admin`. Retrieve the locally stored initial password using `grep '^SPLUNK_PASSWORD=' .env`. Do not paste credentials into shared logs or GitHub. The published `127.0.0.1:8000` bind may not work for `--internal` Docker bridges; use the container address if necessary.

In **Search & Reporting**, set the time range to **All time** and search:

```spl
index=main sourcetype="lab:endpoint" "action=test_message"
| stats count by host
```

Expected: at least one event from `src`, and at least one from `dst`. TCP port accessibility and `pgrep` alone do **not** prove successful ingestion.

## 6. Send real TCP traffic from a UF to another UF

In **terminal 1**, run a temporary receiver in `dst`:

```bash
sudo docker compose exec dst ncat -l -p 8080 --exec /bin/cat
```

In **terminal 2**, send data from `src`:

```bash
sudo docker compose exec src sh -c 'printf "hello from src\n" | ncat -w 3 10.10.2.10 8080'
```

To generate additional connection attempts without `nmap`:

```bash
sudo docker compose exec src sh -c \
  'for p in 20 21 22 23 80 443; do ncat -z -w 1 10.10.2.10 "$p" || :; done'
```

These packets route through `gw`, not through Splunk. You can stop the receiver with Ctrl+C. The endpoint log file is independent of packet capture; **traffic does not automatically produce a log event**. For an explicit activity record:

```bash
sudo docker compose exec -u 0 src sh -c \
  'echo "action=tcp_probe target=10.10.2.10" >> /endpoint-logs/activity.log'
```

Search Splunk with `index=main sourcetype=lab:endpoint action=tcp_probe`.

## 7. Capture the choke point and analyze with Zeek/Arkime

Start this command from `~/homelab` in terminal 1:

```bash
sudo nsenter -t "$(sudo docker inspect -f '{{.State.Pid}}' "$(sudo docker compose ps -q gw)")" -n \
  tcpdump -i eth0 -s 0 -w "$PWD/pcaps/session01.pcap"
```

Generate traffic from terminal 2 using the Ncat commands in section 6, then Ctrl+C the capture in terminal 1.

Analyze with Zeek:

```bash
sudo docker compose exec zeek sh -c \
  'mkdir -p /logs/test && cd /logs/test && zeek -C -r /pcaps/session01.pcap LogAscii::use_json=T'
ls -lh zeek-logs/test/conn.log
```

Splunk monitors `./zeek-logs` and indexes subsequent Zeek JSON logs as `sourcetype=zeek:json`. Search `index=main sourcetype=zeek:json` with **All time**.

Import the same PCAP into Arkime:

```bash
sudo docker compose exec arkime-capture /opt/arkime/bin/capture \
  -c /opt/arkime/etc/config.ini -n labcapture \
  -r /pcaps/session01.pcap --copy
sudo docker compose exec opensearch curl -sS \
  'http://localhost:9200/arkime_sessions3-*/_count'
```

Open `http://10.10.3.21:8005` inside Ubuntu, username `admin`. Retrieve the generated password on a **fresh database** with:

```bash
sudo docker compose exec arkime-viewer cat /opt/arkime/etc/admin-password
```

Then select **Sessions**, time range **All (careful)**, inspect a session, and test **Download PCAP**. If `admin-password` doesn't exist on a preserved database, the old password remains active.

## Notes and limitations

- **Original Splunk image startup is preserved:** no custom UF entrypoint, no manual UF tarball extraction, and no `systemd` workaround.
- **One IP per UF endpoint:** `src` and `dst` are the actual traffic-producing hosts, not separate Ubuntu wrappers around the UFs.
- **No automatic Nmap telemetry:** a UF forwards log files and does not automatically record network activity. Use explicit log generation or install an audit/logging agent for richer telemetry later.
- **No fully live Zeek/Arkime sensor:** PCAP capture, Zeek analysis, and Arkime indexing are currently explicit classroom commands.
- **Static routes:** route jobs must be rerun if Docker recreates a UF container independently. A persistent route agent or a router-based IPAM architecture would be needed for fully self-healing route provisioning.
- **Security:** `--internal` networks reduce external reachability but cannot guarantee containment for real malware. Use VM-level isolation, deny egress explicitly, and do not analyze live malware in this teaching deployment.
- **Splunk passwords:** `.env` is only a seed for initial setup. A preserved named volume can retain a different administrator password.
- **Image builds:** the Red Hat UBI repository must offer the required `microdnf` packages; the host running Docker needs internet access to build the endpoint image. The build will fail explicitly if dependencies cannot be installed.

## Official references

- [Splunk Docker source and image configuration](https://github.com/splunk/docker-splunk)
- [Splunk Universal Forwarder container setup](https://github.com/splunk/docker-splunk/blob/develop/docs/SETUP.md)
- [Splunk receiver configuration](https://help.splunk.com/en/data-management/forward-data/universal-forwarder-manual/10.0/configure-the-universal-forwarder/enable-a-receiver-for-splunk-enterprise)
- [Arkime Docker documentation](https://arkime.com/docker)
