# UDP Cast Reliable Transfer Script

This script provides highly reliable file transfer over gigabit networks using UDP Cast, with automatic management of remote receivers from Ansible inventory.

## Features

- **High Reliability**: Uses Forward Error Correction (FEC) and optimal settings for gigabit networks
- **Ansible Integration**: Automatically reads host lists from Ansible inventory files
- **Remote Management**: Automatically starts and stops UDP receivers on remote hosts
- **Compression Support**: Optional gzip compression for better throughput
- **Comprehensive Logging**: Detailed logging and progress monitoring
- **Error Handling**: Robust error handling with graceful cleanup

## Requirements

- `udp-sender` and `udp-receiver` installed on all hosts
- SSH key-based authentication to all target hosts
- Ansible inventory file with Foundation group (or custom group)
- Gigabit network with proper switching infrastructure

## Installation

1. Copy the script to your system:
```bash
cp udpcast_reliable_transfer.sh /usr/local/bin/
chmod +x /usr/local/bin/udpcast_reliable_transfer.sh
```

2. Create the Ansible inventory file:
```bash
sudo mkdir -p /etc/ansible/inventory/
sudo cp foundation_inventory.example /etc/ansible/inventory/foundation
# Edit the file to match your environment
sudo vim /etc/ansible/inventory/foundation
```

## Usage

### Basic Usage
```bash
# Transfer a disk image to all Foundation hosts
./udpcast_reliable_transfer.sh /path/to/system.img

# Transfer with compression for better throughput
./udpcast_reliable_transfer.sh -c /path/to/backup.tar

# Transfer with custom bandwidth limit
./udpcast_reliable_transfer.sh -b 800m /path/to/image.dd
```

### Advanced Usage
```bash
# Use custom inventory and group
./udpcast_reliable_transfer.sh -i /custom/inventory -g WebServers disk.img

# Dry run to see what would happen
./udpcast_reliable_transfer.sh -d /path/to/test.img

# Verbose output with custom timeout
./udpcast_reliable_transfer.sh -v -t 7200 /path/to/large_image.img
```

## Configuration

### High Reliability Settings
The script is pre-configured with optimal settings for reliable gigabit transfers:

- **FEC**: `16x32` - Strong forward error correction
- **Bandwidth**: `900m` - Conservative limit leaving headroom
- **Slice Size**: `256` - Optimized for gigabit networks
- **Full Duplex**: Enabled for switched networks
- **Retries**: `10` attempts before dropping receivers
- **Timeouts**: Generous timeouts for large transfers

### Network Requirements
For best performance, ensure your network has:
- **Switched infrastructure** (not hubs)
- **IGMP snooping** enabled on switches
- **Flow control disabled** on ports with mixed equipment
- **Broadcast storm control disabled**

## Ansible Inventory Format

The script supports standard Ansible inventory formats:

```ini
[Foundation]
server01.example.com
server02.example.com ansible_host=192.168.1.101
server03.example.com ansible_host=192.168.1.102

[Foundation:vars]
ansible_user=root
ansible_ssh_private_key_file=/root/.ssh/id_rsa
```

## Logging

Logs are written to `/var/log/udpcast/`:
- `udpcast_reliable_transfer.sh.log` - Main script log
- `udp-sender.log` - UDP sender detailed log

Remote receivers log to `/tmp/udp-receiver-<hostname>.log` on each target host.

## Troubleshooting

### Common Issues

1. **SSH Connection Failed**
   - Ensure SSH key authentication is set up
   - Check SSH connectivity: `ssh user@hostname echo "test"`
   - Verify SSH timeout settings

2. **No Receivers Started**
   - Check if `udp-receiver` is installed on target hosts
   - Verify network connectivity and firewall settings
   - Check if ports 9000-9001 are available

3. **Transfer Slow or Failing**
   - Reduce bandwidth limit: `-b 500m`
   - Enable compression: `-c`
   - Check network equipment configuration
   - Monitor logs for packet loss indicators

4. **Inventory Parsing Failed**
   - Verify inventory file format
   - Check group name matches: `-g GroupName`
   - Test with `ansible-inventory -i /path/to/inventory --list`

### Performance Tuning

For optimal performance:
- Use dedicated gigabit network segment
- Ensure all hosts have adequate disk I/O
- Consider using compression for compressible data
- Monitor system resources during transfer

## Security Considerations

- Use SSH key-based authentication
- Consider network segmentation for large transfers
- Monitor network traffic during transfers
- Ensure proper file permissions on image files

## Examples

### Complete System Imaging
```bash
# Image 10 servers with a Linux system image
./udpcast_reliable_transfer.sh -c -v /images/ubuntu-20.04-base.img
```

### Database Backup Distribution
```bash
# Distribute database backup to multiple servers
./udpcast_reliable_transfer.sh -g DatabaseServers /backups/db_backup.tar.gz
```

### High-Speed Data Distribution
```bash
# Maximum performance for local network
./udpcast_reliable_transfer.sh -b 950m -t 3600 /data/large_dataset.bin
```

## Script Options Reference

| Option | Description | Default |
|--------|-------------|---------|
| `-i, --inventory FILE` | Ansible inventory file | `/etc/ansible/inventory/foundation` |
| `-g, --group NAME` | Ansible group name | `Foundation` |
| `-p, --port PORT` | UDP port base | `9000` |
| `-b, --bandwidth RATE` | Max bandwidth | `900m` |
| `-c, --compression` | Enable gzip compression | Disabled |
| `-d, --dry-run` | Show actions without executing | Disabled |
| `-t, --timeout SECONDS` | Transfer timeout | `3600` |
| `-v, --verbose` | Verbose output | Disabled |
| `-h, --help` | Show help | - |

For more information about UDP Cast itself, see the included PDF documentation.
