# Copy the script to a system location
sudo cp id_monitor.sh /usr/local/bin/id_monitor.sh
sudo chmod +x /usr/local/bin/id_monitor.sh

# Install and enable the systemd service
sudo cp gmrs-id-monitor.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable id-monitor
sudo systemctl start id-monitor
