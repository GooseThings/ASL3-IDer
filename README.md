# Copy the script to a system location
- sudo cp id_monitor.sh /usr/local/bin/id_monitor.sh
- sudo chmod +x /usr/local/bin/id_monitor.sh
- sudo chmod 755 /usr/local/bin/id_monitor.sh

# Install and enable the systemd service
- sudo cp gmrs-id-monitor.service /etc/systemd/system/
- sudo systemctl daemon-reload
- sudo systemctl enable id-monitor
- sudo systemctl start id-monitor

# Live status
sudo systemctl status id-monitor

# Follow the log
sudo tail -f /var/log/id_monitor.log

# Stop it
sudo systemctl stop id-monitor
