# LibreNMS install on Ubuntu

This script installs LibreNMS on Ubuntu server.

This was tested using ubuntu-24-04-2-live-server-amb64.iso

Do sudo bash before running the script.

For the web server host name, if you don't have a valid DNS name, use the IP address of the server.

The MySQL database password can be anything. This just sets it in the database itself, and the .env file for librenms to use it.

The timezone is set to Brisbane because I didn't want to keep typing it. Change it to what you need.


