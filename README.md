# Remote Network Manager

A robust tool for managing virtual NICs and Guest WiFi on remote Linux machines (like Kali) while maintaining continuous, unbreakable SSH connectivity.

This tool is specifically designed for remote "black box" and PCI DSS segmentation testing (e.g., verifying isolation between non-CDE networks like Guest WiFi/Voice VLANs and the CDE) where physical access to the testing machine is not available, and getting locked out is not an option.

## Features
- **Dynamic SSH Protection**: Automatically detects the primary wired interface holding the default route and enforces strict SSH origin route pinning (`/32` host route back to your connecting client IP).
- **Anti-Bridging**: Explicitly disables IPv4 and IPv6 forwarding during setup to guarantee the testing box behaves strictly as an endpoint, preventing accidental routing between CDE and non-CDE networks.
- **VLAN Mode**: Batch creation of 802.1Q sub-interfaces with static IPs.
- **Source-Based Routing (PBR)**: Automatically configures Policy-Based Routing via a custom routing table. Test traffic originating from the VLAN IP is forced out of the VLAN Gateway, allowing you to scan massive CDE subnets (/24, /21) without modifying the primary routing table.
- **NAC-Safe MAC Spoofing**: Inherits the primary interface's MAC address by default to avoid triggering switchport security (MAC limits) or `err-disable` states, while allowing targeted, optional MAC spoofing (e.g., for MAB bypass on Voice VLANs).
- **Guest WiFi Mode**: Interactive, DHCP-safe WiFi connection. Deprioritizes DHCP-provided default routes (using metric 999) to prevent routing hijacking.
- **Safety Rollback Timer**: A 120-second "dead man's switch" confirmation window. If the SSH session drops or confirmation is missed, the script automatically reverts all network changes.
- **Cleanup Mode**: Safely tears down all created VLANs, test WiFi profiles, and custom routing policies (`ip rules`), restoring the system to a clean state.

## Installation

### Prerequisites
The script relies on native Linux networking tools. Ensure they are installed:
```bash
sudo apt-get update
sudo apt-get install -y iproute2 network-manager iw procps gawk grep
```

### Setup
```bash
git clone https://github.com/yourusername/remote-net-manager.git
cd remote-net-manager
chmod +x bin/remote-net-mgr.sh
```

## Usage

The script must be executed with root privileges to modify network interfaces and routing tables.

```bash
sudo ./bin/remote-net-mgr.sh {vlan|wifi|cleanup}
```

### Examples & Expected Output

#### 1. VLAN Mode (Batch Creation, MAC Spoofing, & Source-Based Routing)
*In this example, we create VLAN 200, spoof a VoIP MAC address, and provide a Gateway. The script configures Source-Based Routing so testing tools bind seamlessly to the CDE target.*

```text
$ sudo ./bin/remote-net-mgr.sh vlan
[*] Detected primary interface: eth0 (Gateway: 192.168.1.1). This interface will be protected.
[*] Disabling IP forwarding to prevent accidental bridging/routing...
[*] Pinning SSH origin route for 10.0.0.55 via 192.168.1.1 dev eth0...
Available physical interfaces:
eth0
Enter base interface for VLANs (e.g., eth0): eth0
[*] Warning: You are adding VLANs to the primary SSH interface. Routing will not be touched.
Enter VLAN IDs to create (comma-separated, e.g., 10,20,30): 200
Enter static IP/CIDR for VLAN 200 (e.g., 192.168.10.5/24): 10.200.200.50/24
Enter custom MAC address for VLAN 200 (leave blank to inherit primary MAC): 00:1A:2B:3C:4D:5E
[*] Creating VLAN interface eth0.200...
[*] Assigning custom MAC address 00:1A:2B:3C:4D:5E to eth0.200...
[*] Assigning IP 10.200.200.50/24 to eth0.200...
[*] Bringing up eth0.200...
Enter VLAN Gateway IP (optional, for Source-Based Routing to CDE): 10.200.200.1
[*] Configuring Source-Based Routing for 10.200.200.50 via 10.200.200.1 (Table 300)...
[*] Routing configured. Any traffic originating from 10.200.200.50 will be forced through eth0.200.
[*] VLAN setup complete.
[*] Initiating safety rollback timer (120 seconds)...
[*] Please confirm the connection is stable and you still have SSH access.
Type 'confirm' to keep settings, or press Enter to rollback: confirm

[*] Configuration confirmed by operator. Rollback cancelled.
```

#### 2. Guest WiFi Mode (DHCP-Safe)
*In this example, we connect to a corporate guest network. The script ensures the DHCP address we receive doesn't overwrite our primary management route.*

```text
$ sudo ./bin/remote-net-mgr.sh wifi
[*] Detected primary interface: eth0 (Gateway: 192.168.1.1). This interface will be protected.
[*] Disabling IP forwarding to prevent accidental bridging/routing...
[*] Pinning SSH origin route for 10.0.0.55 via 192.168.1.1 dev eth0...
[*] Using WiFi interface: wlan0
Do you want to scan for SSIDs? (y/n): y
[*] Scanning for networks (this may take a few seconds)...
IN-USE  BSSID              SSID             MODE   CHAN  RATE        SIGNAL  BARS  SECURITY
        00:11:22:33:44:55  Corp_Guest       Infra  6     130 Mbit/s  80      ▂▄▆_  WPA2
Enter target SSID (or manual/hidden SSID): Corp_Guest
Enter WiFi password (leave blank for open):

[*] Configuring Guest WiFi...
[*] Securing routing table (deprioritizing WiFi routes to protect SSH)...
[*] Connecting to Corp_Guest...
[*] WiFi connection successful. Waiting to acquire DHCP...
wlan0            UP             172.16.50.102/24
[*] Initiating safety rollback timer (120 seconds)...
[*] Please confirm the connection is stable and you still have SSH access.
Type 'confirm' to keep settings, or press Enter to rollback: confirm

[*] Configuration confirmed by operator. Rollback cancelled.
```

#### 3. Cleanup Mode
*After testing is complete, or if a test fails, easily restore the system state without rebooting.*

```text
$ sudo ./bin/remote-net-mgr.sh cleanup
[*] Detected primary interface: eth0 (Gateway: 192.168.1.1). This interface will be protected.
[*] Disabling IP forwarding to prevent accidental bridging/routing...
[*] Pinning SSH origin route for 10.0.0.55 via 192.168.1.1 dev eth0...
[*] Starting cleanup mode...
[*] Removing VLAN interface: eth0.200
[*] Removing Guest WiFi connection profile...
[*] Cleanup complete.
