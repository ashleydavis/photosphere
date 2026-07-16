# LAN sharing in the Android emulator

`apps/android-frontend/scripts/emulator-lan-bridge.sh` puts the Android emulator on a real network segment shared with your host, so you can use LAN sharing between the Electron app and the emulator. Without it, sharing to the emulator always fails with "No sender connected within 60 seconds".

## Why it is needed

By default the emulator runs behind a virtual router on the 10.0.2.x network, which is deliberately isolated from the host. Google's [network address space docs](https://developer.android.com/studio/run/emulator-networking-address) put it plainly: "each instance of the emulator runs behind a virtual router or firewall service that isolates it from your development machine network interfaces and settings and from the internet. An emulated device can't detect your development machine or other emulator instances on the network." The same page confirms the guest cannot be reached from the host except through the `10.0.2.2` loopback alias, and that "the emulator does not support IGMP", so multicast discovery is out too.

LAN sharing needs both of those. The receiver broadcasts `PSIE_RECV:<port>:<fingerprint>` to `255.255.255.255:54321` once a second, and the sender, on hearing that broadcast, opens a cert-pinned HTTPS connection back to the address the broadcast arrived from. Under user-mode NAT the broadcast is never heard, so the receiver waits out its full 60 second timeout and reports that no sender connected. Nothing is wrong with the app code: the two ends simply cannot see each other.

The script creates a private bridge (a virtual layer-2 switch in the host kernel) with two ports on it: the host, and a tap interface the emulator attaches its virtual wifi to. Because both ends are ports on one switch, a broadcast from the guest is flooded to the host's port too, and the host can address the guest directly. That is a genuine network segment, so discovery and the transfer behave exactly as they would between two real machines.

It does not bridge your physical NIC, and does not need to, because the emulator runs on the same host. That keeps your real network out of it entirely, so a mistake here cannot drop your machine off the network.

## Requirements

- Linux. This uses `ip`, tap interfaces, and `dnsmasq`, which are Linux specific.
- `dnsmasq` installed (`sudo apt install dnsmasq` on Ubuntu/Debian). The script checks and tells you if it is missing.
- Root for `up` and `down`, because creating network interfaces requires it. `status` does not need root.
- An AVD on API 31 or newer. Those use VirtioWifi, which is what `-wifi-tap` attaches to.

## Usage

Bring the segment up. This is a one time thing per boot, not per test run:

```
sudo apps/android-frontend/scripts/emulator-lan-bridge.sh up
```

Start the emulator attached to the tap, as your normal user rather than root:

```
"${ANDROID_HOME:-$HOME/Android/Sdk}/emulator/emulator" -avd <your-avd> -wifi-tap emu-netcard
```

Confirm the guest actually landed on the segment:

```
apps/android-frontend/scripts/emulator-lan-bridge.sh status
```

You want a `192.168.55.x` address against the guest. If you see `10.0.2.16` instead (the emulator's default Wi-Fi address, per the [address space docs](https://developer.android.com/studio/run/emulator-networking-address)), the emulator ignored `-wifi-tap` and is still behind the virtual router, so sharing will not work. See troubleshooting below.

Tear it all down when you are finished:

```
sudo apps/android-frontend/scripts/emulator-lan-bridge.sh down
```

## Reversing it

Everything this script does is runtime only. It writes no configuration files: nothing in `/etc`, no NetworkManager or netplan connections, no `iptables-save`, no `sysctl.conf`. So there are two ways back, and the second one always works.

**Normal teardown**, which restores each thing it changed:

```
sudo apps/android-frontend/scripts/emulator-lan-bridge.sh down
```

**Reboot.** Every change made here lives in kernel runtime state, so a reboot clears all of it whether or not `down` ran, or ran correctly. If something looks wrong and you want out, reboot and you are back to a clean machine.

What `down` restores:

| Changed by `up` | Restored by `down` |
|---|---|
| The `br-psphere` bridge and its address | Deleted |
| The `emu-netcard` interface | Deleted |
| The dnsmasq DHCP server | Killed via its pid file, with a fallback that matches only our bridge so it cannot hit another dnsmasq |
| `net.ipv4.ip_forward` | Set back to the exact value it had before |
| The NAT and FORWARD iptables rules | Deleted individually by rule spec |

What `down` deliberately does not undo:

- **The `tun` kernel module** stays loaded. Unloading it could break anything else using tap interfaces, such as a VPN or another VM, and a loaded module with nothing attached costs nothing.
- **The dnsmasq log** at `/tmp/psphere-emulator-dnsmasq.log` is left for you to read after a failure. Delete it whenever.

## What it cannot break

- **Your physical network.** `enp131s0` and equivalents are never touched, by design. The bridge is private and shares no port with your real NIC, so no failure here can take your machine off the network.
- **Your routing to real networks.** The only route added is for `192.168.55.0/24`, chosen to be unlikely to collide with a real LAN. If you do happen to use `192.168.55.x`, change `BRIDGE_ADDRESS` and `BRIDGE_SUBNET` at the top of the script before running it, because that is the one case where this could shadow a network you care about.
- **Other firewall rules.** The iptables rules are scoped to `br-psphere` by interface match, and are added with a `-C` existence test first, so re-running `up` cannot stack duplicates.

## Trying a share

With the segment up and the emulator running on it:

1. Start the Electron app on the host and the Photosphere app in the emulator.
2. In the emulator, open Receive Database and enter the 4 digit pairing code shown by the sender.
3. On the host, pick a database and click Share, using that same code.

The host and the guest are now on one segment, so the emulator's broadcast reaches the Electron app and the HTTPS transfer connects straight back to the guest's `192.168.55.x` address.

## What it sets up

| Piece | Value | Purpose |
|---|---|---|
| Bridge | `br-psphere` | The virtual switch both ends plug into. Broadcast is flooded across its ports, which is what makes discovery work. |
| Host address | `192.168.55.1` | The host's port on the segment, and the guest's default gateway. |
| Tap | `emu-netcard` | The virtual NIC the emulator attaches to. Owned by your user, since the emulator is not root. |
| DHCP | `192.168.55.50` to `192.168.55.150` | Android runs a DHCP client on `wlan0` as soon as it associates, so something has to answer or the interface stays unusable. |
| NAT | via your default route | Gives the guest internet through the host's uplink. Not needed for sharing, but an emulator with no internet is painful and Android flags the network as unvalidated without it. |

Override the DNS server handed to the guest with `GUEST_DNS` if you would rather it used your own resolver:

```
sudo GUEST_DNS=192.168.20.1 apps/android-frontend/scripts/emulator-lan-bridge.sh up
```

## Troubleshooting

**The guest still has a `10.0.2.x` address.** The emulator ignored `-wifi-tap` and is still behind the virtual router. Check that you passed the flag to the `emulator` binary directly rather than launching from Android Studio, which starts its own emulator process without your arguments. Be aware that `-wifi-tap` is undocumented (see the caveat below), so if this persists the flag may simply not be wired up in your emulator build.

**The guest has no address at all.** DHCP is not being answered. Check the dnsmasq log at `/tmp/psphere-emulator-dnsmasq.log` for `DHCPDISCOVER` lines. No lines at all means the guest's frames are not reaching the bridge, so check `apps/android-frontend/scripts/emulator-lan-bridge.sh status` shows `emu-netcard` as a port on the bridge.

**dnsmasq will not start.** Usually something else already holds the DHCP port. The script runs it with `--port=0` so it does not fight systemd-resolved over DNS on port 53, but a second dnsmasq or a libvirt network can still clash. Check with `ss -lnup | grep :67`.

**The emulator will not open the tap.** It runs as your user and can only open a tap it owns. If you created the tap by hand, or ran the emulator with sudo, ownership will be wrong. Run `down` then `up` again to recreate it with the right owner.

**Sharing still times out with everything above correct.** Confirm both ends are actually on the segment: the guest should have a `192.168.55.x` address and the host should answer `ping 192.168.55.1` from `adb shell`. If the guest can ping the host but sharing still times out, the problem is in the app rather than the network.

## Caveats and sources

The isolation this script works around is documented. The workaround itself is not, so the two deserve different levels of trust.

**`-wifi-tap` is undocumented.** It is present in `emulator -help` on the installed binary, but it does not appear in Google's [emulator command line reference](https://developer.android.com/studio/run/emulator-commandline). Nothing published promises it works or that it will keep working. It is the one step here worth proving before relying on any of it. The related `-shared-net-id` option is listed as deprecated on that same page, which suggests this corner of the emulator gets little attention.

**Emulator 36.5 does not solve this.** 36.5 [added a new Wi-Fi networking stack](https://developer.android.com/studio/releases/emulator) that puts multiple AVDs on a shared virtual network with zero configuration. It is tempting to think it removes the need for this script, but it does not: the [interconnect docs](https://developer.android.com/studio/run/emulator-networking-interconnect) and the [announcement](https://developer.android.com/blog/posts/test-multi-device-interactions-with-the-android-emulator) both describe it as a "shared virtual network backplane that bridges all running instances on the same host machine", which is emulator to emulator. The host is not a participant, and host to guest is exactly what LAN sharing needs. If you are on 36.5+ and hit odd behaviour, that stack can be turned off with `emulator -feature -WiFiPacketStream`.

**One inference, not a quote.** The docs state the isolation and that IGMP is unsupported, but do not spell out in so many words that UDP broadcast fails to cross from the guest to the host. That specific step is inferred from the documented isolation, and is consistent with the observed symptom (the receiver waits its full 60 seconds and reports no sender). If you ever see it behave otherwise, this reasoning is what to re-check first.

Sources:

- [Network address space](https://developer.android.com/studio/run/emulator-networking-address) for the isolation statement, the 10.0.2.x assignments, and the IGMP limitation.
- [Emulator command line reference](https://developer.android.com/studio/run/emulator-commandline) for the absence of `-wifi-tap` and the deprecation of `-shared-net-id`.
- [Emulator release notes](https://developer.android.com/studio/releases/emulator) and [Test multi-device interactions](https://developer.android.com/blog/posts/test-multi-device-interactions-with-the-android-emulator) for what 36.5 changed.
