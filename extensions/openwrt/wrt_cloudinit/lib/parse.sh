# shellcheck shell=dash
# Чистые парсеры NoCloud v1 (Proxmox). Без сайд-эффектов.

# parse_netcfg <network-config> → построчно: iface|proto|ip|mask|gw
parse_netcfg() {
	awk '
		function ind(s){match(s,/^[ ]*/);return RLENGTH}
		function flush(){
			if(iface){
				p = proto ? proto : "dhcp"
				printf "%s|%s|%s|%s|%s\n", iface, p, ip, mask, gw
			}
			in_phys = 0; iface = proto = ip = mask = gw = ""; phys_ind = -1
		}
		/^[ ]*-[ ]*type:[ ]*physical/                       { flush(); in_phys=1; phys_ind=ind($0); next }
		in_phys && /^[ ]*-[ ]*type:/ && ind($0) <= phys_ind { flush(); next }
		in_phys {
			if($0~/^[ ]*name:/)             iface = $2
			if($0~/-[ ]*type:[ ]*static/)   proto = "static"
			if($0~/-[ ]*type:[ ]*dhcp4/)    proto = "dhcp"
			if($0~/^[ ]*address:/)          ip   = $2
			if($0~/^[ ]*netmask:/)          mask = $2
			if($0~/^[ ]*gateway:/)          gw   = $2
		}
		END{ flush() }
	' "$1" | tr -d "\"'"
}

# read_dns <network-config> → DNS|search (первый address и первый search)
read_dns() {
	awk '
		/^[ ]*-?[ ]*type:[ ]*nameserver/ { ns=1; mode=""; next }
		ns && /^[ ]*-[ ]*type:/          { ns=0 }
		ns && /^[ ]*address:/            { mode="dns";    next }
		ns && /^[ ]*search:/             { mode="search"; next }
		ns && /^[ ]*-/ {
			v=$0; sub(/^[ ]*-[ ]*/,"",v)
			if (mode=="dns"    && dns=="")  { gsub(/[^0-9.]/,"",v);         dns=v }
			if (mode=="search" && srch=="") { gsub(/[^A-Za-z0-9_.-]/,"",v); srch=v }
		}
		END { print dns"|"srch }
	' "$1"
}

# get_seed_instance_id <meta-data> → instance-id (пусто при отсутствии)
get_seed_instance_id() {
	awk -F': *' '$1=="instance-id"{print $2; exit}' "$1" 2>/dev/null | tr -d " \"'"
}

# validate_netcfg <network-config> → 0, если есть хотя бы один интерфейс
validate_netcfg() {
	parse_netcfg "$1" | grep -q '^[^|][^|]*|'
}
