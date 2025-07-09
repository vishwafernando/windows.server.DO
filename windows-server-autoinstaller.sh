#!/bin/bash

# --- Configuration Variables ---
# Adjust these based on your Droplet's resources and preferences
VM_RAM="4G" # Minimum 4G, consider 8G or more for Windows Server
VM_CPUS="2" # Number of virtual CPUs
VM_DISK_SIZE="60G" # Recommended 60G-80G for Windows Server, adjust as needed
VNC_DISPLAY_PORT=":0" # :0 means port 5900, :1 means 5901, etc.
BRIDGE_NAME="br0" # Name of the network bridge on your Linux host

# --- Function to display menu and get user choice ---
display_menu() {
    echo "----------------------------------------------------"
    echo "  Windows OS Installer for DigitalOcean Droplets  "
    echo "----------------------------------------------------"
    echo "Please select the Windows Server or Windows version:"
    echo "1. Windows Server 2016 (Official Evaluation)"
    echo "2. Windows Server 2019 (Official Evaluation)"
    echo "3. Windows Server 2022 (Official Evaluation)"
    echo "4. Windows Server 2025 (Official Evaluation)"
    echo "5. Windows 11 (UNOFFICIAL SOURCE - USE WITH CAUTION!)"
    echo "6. Windows 10 21H2 (UNOFFICIAL SOURCE - USE WITH CAUTION!)"
    echo "----------------------------------------------------"
    read -p "Enter your choice (1-6): " choice
}

# --- Initial System Setup ---
echo "--- Starting initial system setup (update & upgrade) ---"
sudo apt update && sudo apt upgrade -y
echo "--- System setup complete ---"

echo "--- Installing QEMU and virtualization utilities ---"
# Install core QEMU components and bridge utilities
# `qemu-kvm` is usually sufficient and pulls in necessary dependencies.
# `bridge-utils` is essential for bridged networking.
sudo apt install qemu-kvm bridge-utils -y
echo "--- QEMU and utilities installation complete ---"

# --- Network Bridge Configuration ---
echo "--- Configuring Network Bridge ($BRIDGE_NAME) ---"
echo "This step modifies your Droplet's network configuration. Be careful!"
echo "It assumes your primary network interface is 'eth0' or 'ens3'."
echo "You might temporarily lose SSH connection if misconfigured. Have DO console ready."

# Find the primary network interface (e.g., eth0, ens3)
# This tries to be smart, but you might need to manually verify with `ip a`
PRIMARY_INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|enp|ens)[0-9]+' | head -n 1)

if [ -z "$PRIMARY_INTERFACE" ]; then
    echo "ERROR: Could not automatically detect primary network interface. Please identify it manually (e.g., eth0, ens3) and update the script."
    exit 1
fi

echo "Detected primary network interface: $PRIMARY_INTERFACE"

# Backup existing netplan configuration
sudo cp /etc/netplan/*.yaml /etc/netplan/original_netplan_config_backup_$(date +%Y%m%d%H%M%S).yaml

# Create a new netplan config for the bridge
# This overwrites any existing 50-cloud-init.yaml, so backup is important
sudo bash -c "cat > /etc/netplan/50-cloud-init.yaml <<EOF
network:
  ethernets:
    $PRIMARY_INTERFACE:
      dhcp4: no # Disable DHCP on the physical interface
  bridges:
    $BRIDGE_NAME:
      interfaces: [$PRIMARY_INTERFACE] # Connect physical interface to the bridge
      dhcp4: true       # Enable DHCP on the bridge
      parameters:
        stp: false      # Spanning Tree Protocol off
        forward-delay: 0 # No delay
  version: 2
EOF"

echo "Applying netplan configuration. You might briefly lose SSH connection."
sudo netplan try # Test the configuration
# If netplan try is successful, it will prompt you to press Enter to apply, or wait to revert.
# The script will pause here until you manually press Enter or it reverts.
sudo netplan apply # Apply the configuration permanently

echo "--- Network bridge configuration complete. Verifying... ---"
ip a | grep "$BRIDGE_NAME"
if [ $? -eq 0 ]; then
    echo "Bridge $BRIDGE_NAME successfully configured."
else
    echo "ERROR: Bridge $BRIDGE_NAME not found or not configured correctly. Please check manually."
    exit 1
fi

# Create qemu-ifup and qemu-ifdown scripts for TAP device management
echo "--- Creating QEMU network helper scripts ---"
sudo bash -c "cat > /etc/qemu-ifup <<EOF
#!/bin/sh
# Script to bring up a tap device and add it to a bridge
# Usage: /etc/qemu-ifup <tap_device_name>

BR_NAME=\"$BRIDGE_NAME\"
TAP_NAME=\"\$1\"

ip link show \"\$BR_NAME\" > /dev/null 2>&1
if [ \$? -ne 0 ]; then
    echo \"Bridge \$BR_NAME does not exist. Exiting.\"
    exit 1
fi

ip tuntap add dev \"\$TAP_NAME\" mode tap user \$(whoami)
ip link set \"\$TAP_NAME\" up
ip link set \"\$TAP_NAME\" master \"\$BR_NAME\"

echo \"TAP device \$TAP_NAME added to bridge \$BR_NAME.\"
EOF"
sudo chmod +x /etc/qemu-ifup

sudo bash -c "cat > /etc/qemu-ifdown <<EOF
#!/bin/sh
# Script to take down a tap device and remove it from a bridge
# Usage: /etc/qemu-ifdown <tap_device_name>

TAP_NAME=\"\$1\"

ip link set \"\$TAP_NAME\" nomaster
ip link set \"\$TAP_NAME\" down
ip tuntap del dev \"\$TAP_NAME\" mode tap

echo \"TAP device \$TAP_NAME removed.\"
EOF"
sudo chmod +x /etc/qemu-ifdown
echo "--- QEMU network helper scripts created ---"


# --- Get user choice for Windows Version ---
display_menu

case $choice in
    1)
        img_file="windows2016.img"
        iso_link="https://go.microsoft.com/fwlink/p/?LinkID=2195174&clcid=0x409&culture=en-us&country=US"
        iso_file="windows2016.iso"
        ;;
    2)
        img_file="windows2019.img"
        iso_link="https://go.microsoft.com/fwlink/p/?LinkID=2195167&clcid=0x409&culture=en-us&country=US"
        iso_file="windows2019.iso"
        ;;
    3)
        img_file="windows2022.img"
        iso_link="https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US"
        iso_file="windows2022.iso"
        ;;
    4)
        img_file="windows2025.img"
        iso_link="https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us"
        iso_file="windows2025.iso"
        ;;
    5)
        img_file="windows11.img"
        # WARNING: Unofficial source. Use official Microsoft ISOs if possible.
        iso_link="http://206.189.48.156/WIN11.ISO"
        iso_file="windows11.iso"
        ;;
    6)
        img_file="windows1021h2.img"
        # WARNING: Unofficial source. Use official Microsoft ISOs if possible.
        iso_link="http://206.189.48.156/win1021H2.img"
        iso_file="windows1021h2.iso"
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

echo "Selected version: $(echo $iso_file | sed 's/\.iso//g' | sed 's/\.img//g')"

# --- Create Virtual Disk Image ---
echo "--- Creating virtual disk image: $img_file (Size: $VM_DISK_SIZE) ---"
qemu-img create -f raw "$img_file" "$VM_DISK_SIZE"
echo "--- Image file $img_file created successfully ---"

# --- Download VirtIO Driver ISO ---
echo "--- Downloading VirtIO driver ISO ---"
wget -O virtio-win.iso 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.215-1/virtio-win-0.1.215.iso'
echo "--- VirtIO driver ISO downloaded successfully ---"

# --- Download Windows ISO ---
echo "--- Downloading Windows ISO: $iso_file ---"
wget -O "$iso_file" "$iso_link"
echo "--- Windows ISO downloaded successfully ---"

# --- Start QEMU Virtual Machine ---
echo "--- Starting QEMU Virtual Machine for Windows Installation ---"
echo "Connect to VNC at: your_droplet_ip:$((5900 + ${VNC_DISPLAY_PORT//:/}))"
echo "Remember to set up SSH tunneling for security: ssh -L $((5900 + ${VNC_DISPLAY_PORT//:/})):localhost:$((5900 + ${VNC_DISPLAY_PORT//:/})) user@your_droplet_ip"
echo "Press Ctrl+C in this terminal to stop the VM after installation."

# The QEMU command to start the VM
# -smp: Number of virtual CPUs
# -m: RAM for the VM
# -cpu host: Pass through host CPU features for better performance
# -enable-kvm: Enable KVM hardware virtualization
# -boot order=d: Boot from CD-ROM first
# -drive file=...img,format=raw,if=virtio: Main virtual disk, using VirtIO for performance
# -cdrom ...iso: Windows installation ISO
# -drive file=virtio-win.iso,media=cdrom: VirtIO drivers ISO, crucial for Windows to see virtual hardware
# -netdev tap,id=net0,script=/etc/qemu-ifup,downscript=/etc/qemu-ifdown: Connects to the TAP device managed by our scripts
# -device virtio-net-pci,netdev=net0: Uses VirtIO network adapter
# -device usb-ehci,id=usb,bus=pci.0,addr=0x4: USB 2.0 controller (optional, but harmless)
# -device usb-tablet: Improves mouse integration in VNC
# -vnc :0: Starts VNC server on display 0 (port 5900)

qemu-system-x86_64 \
-smp "$VM_CPUS" \
-m "$VM_RAM" \
-cpu host \
-enable-kvm \
-boot order=d \
-drive file="$img_file",format=raw,if=virtio \
-cdrom "$iso_file" \
-drive file=virtio-win.iso,media=cdrom \
-netdev tap,id=net0,script=/etc/qemu-ifup,downscript=/etc/qemu-ifdown \
-device virtio-net-pci,netdev=net0 \
-device usb-ehci,id=usb,bus=pci.0,addr=0x4 \
-device usb-tablet \
-vnc "$VNC_DISPLAY_PORT"

echo "--- QEMU VM process finished ---"
echo "Remember to remove the -cdrom and virtio-win.iso from the QEMU command and change -boot order=c (boot from hard disk) after installation."
echo "You can then restart the VM by running the modified QEMU command."
