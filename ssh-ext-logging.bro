@load ssh-ext

module SSH;

export {
	# If set to T, this will split inbound and outbound transactions
	# into separate files.  F merges everything into a single file.
	const split_log_file = F &redef;
	# Which SSH logins to record.
	# Choices are: Inbound, Outbound, All
	const logging = All &redef;
}

event bro_init()
	{
	LOG::create_logs("ssh-ext", logging, split_log_file);
	}

event ssh_ext(id: conn_id, si: ssh_ext_session_info)
	{
	local log = LOG::choose("ssh-ext", id$resp_h);

	print log, cat_sep("\t", "\\N", 
	                   si$start_time,
	                   id$orig_h, fmt("%d", id$orig_p),
	                   id$resp_h, fmt("%d", id$resp_p),
	                   si$status, si$direction, 
	                   si$location$country_code, si$location$region,
	                   si$client, si$server,
	                   si$resp_size);
	}