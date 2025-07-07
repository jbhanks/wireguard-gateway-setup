# Wireguard Gateway Setup
Creates up a Vultr VPS instance and sets up on it a Wireguard VPN for accessing private self-hosted services, then creates a local wirgeguard configuration in `/etc/wireguard/`

Pre-requisites:
1. Install dependencies: `wireguard`, `ansible`, `go-yq`, `jq`
3. Make sure that you have API access to your Vultr account enabled and an api token generated.


WARNING: THIS WILL OVERWRITE YOUR LOCAL `/etc/wireguard/wg-client.conf`!!!
Usage:
1. If you already have a Wireguard config at `/etc/wireguard/wg-client.conf`, back it up with `sudo cp  `/etc/wireguard/wg-client.conf` `/etc/wireguard/wg-client.conf.bak`
2. Fill out vars.yaml.dist with your variables and rename it to vars.yaml. `ssh_key_base` is the path the the private ssh key that will be used for authentication and provisioning. The script assumes that the public key is in the same folder and is call `ssh_key_base.pub`
3. Run `sh wrapper.sh $vultr_api_token`
4. Run `wg-quick down wg-client` if the wg client is active, otherwise skip to the next step. Change the name if your current wg config is called something other than `wg-client.conf`
5. Run `wg-quick up wg-client`
6. Test that you can access your target server and the internet properly.
7. Obviously, make sure you configure your web server hosting your private services to only allow connections from the VPN IP, or this whole thing is pointless ;)
