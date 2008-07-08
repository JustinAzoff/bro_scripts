# Copyright 2008 Seth Hall <hall.692@osu.edu>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that: (1) source code distributions
# retain the above copyright notice and this paragraph in its entirety, (2)
# distributions including binary code include the above copyright notice and
# this paragraph in its entirety in the documentation or other materials
# provided with the distribution, and (3) all advertising materials mentioning
# features or use of this software display the following acknowledgement:
# ``This product includes software developed by the University of California,
# Lawrence Berkeley Laboratory and its contributors.'' Neither the name of
# the University nor the names of its contributors may be used to endorse
# or promote products derived from this software without specific prior
# written permission.
# THIS SOFTWARE IS PROVIDED ``AS IS'' AND WITHOUT ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE.

@load smtp
@load global-ext
@load functions-ext

module SMTP;

export {
	global smtp_ext_log = open_log_file("smtp_ext") &raw_output &redef;

	redef enum Notice += { 
		# Thrown when a local host receives a reply mentioning an smtp block list
		SMTP_BL_Error_Message, 
		# Thrown when the local address is seen in the block list error message
		SMTP_BL_Blocked_Host, 
	};

	# This matches content in SMTP error messages that indicate some block list doesn't like the connection/mail.
	const smtp_bl_error_messages = 
	    /www\.spamhaus\.org\//
	  | /cbl\.abuseat\.org\// &redef;
}

type session_info: record {
	msg_id: string;
	in_reply_to: string;
	helo: string;
	mailfrom: string;
	rcptto: string_set;
	date: string;
	from: string;
	to: string_set;
	reply_to: string;
	last_reply: string &default=""; # last message the server sent to the client
};


function default_session_info(): session_info
	{
	local tmp: string_set = set();
	local tmp2: string_set = set();
	return [$msg_id="", $in_reply_to="", $helo="", $rcptto=tmp, $mailfrom="", $date="", $from="", $to=tmp2, $reply_to=""];
	}
# TODO: setting a default function doesn't seem to be working correctly here.
global conn_info: table[conn_id] of session_info &read_expire=10secs;

global in_received_from_headers: set[conn_id] &create_expire = 2min;
global smtp_received_finished: set[conn_id] &create_expire = 2min;
global smtp_forward_paths: table[conn_id] of string &create_expire = 2min &default = "";


function find_address_in_smtp_header(header: string): string
{
	local text_ip = "";
	local parts: string_array;
	if ( /\[.*\]/ in header )
		parts = split(header, /[\[\]]/);
	else if ( /\(.*\)/ in header )
		parts = split(header, /[\(\)]/);

	if (|parts| > 1)
		{
		if ( |parts| > 3 && parts[4] == ip_addr_regex )
			text_ip = parts[4];
		else if ( parts[2] == ip_addr_regex )
			text_ip = parts[2];
		}
	return text_ip;
}

# This event handler builds the "Received From" path by reading the 
# headers in the mail
event smtp_data(c: connection, is_orig: bool, data: string)
	{
	# only build this trace for mail emanating from our networks
	if ( !is_local_addr(c$id$orig_h) ) return;

	local id = c$id;
	if ( id !in smtp_sessions )
		return; # bro is not analyzing it as a smtp session
	
	if ( /^[^[:blank:]]*?: / in data && id !in smtp_received_finished ) 
		delete in_received_from_headers[id];
	if ( /^Received: / in data && id !in smtp_received_finished ) 
		add in_received_from_headers[id];
	
	local session = smtp_sessions[id];
	if ( session$in_header &&              # headers are currently being analyzed 
	     id in in_received_from_headers && # currently seeing received from headers
	     id !in smtp_received_finished &&  # we don't want to stop seeing this message yet
	     /[\[\(]/ in data )                # the line might contain an ip address
		{
		local text_ip = find_address_in_smtp_header(data);
    
		# check for valid-ish ip - some mtas are weird and I don't want to create any vulnerabilities.
		if ( is_valid_ip(text_ip) )
			{
			local ip = to_addr(text_ip);
    
			if ( (is_local_addr(ip) || ip in private_address_space) &&
			     ip != 127.0.0.1 ) # I don't care if mail bounces around on localhost
				{
				if (smtp_forward_paths[id] == "")
					smtp_forward_paths[id] = fmt("%s", ip);
				else
					smtp_forward_paths[id] = fmt("%s -> %s", ip, smtp_forward_paths[id]);
				} 
			else 
				{
				if (smtp_forward_paths[id] == "")
					smtp_forward_paths[id] = fmt("outside (%s)", ip);
				else
					smtp_forward_paths[id] = fmt("outside (%s) -> %s", ip, smtp_forward_paths[id]);
				
				add smtp_received_finished[id]; 
				}
			}
		
			
		} 
	else if ( !session$in_header && id !in smtp_received_finished ) 
		{
		add smtp_received_finished[id];
		}
	}


function end_smtp_extended_logging(id: conn_id)
	{
	if ( id !in conn_info )
		return;

	local conn_log = conn_info[id];
	
	local forward_path = "";
	if ( id in smtp_forward_paths )
		forward_path = smtp_forward_paths[id];

	print smtp_ext_log, cat_sep("\t", "\\N", network_time(), 
	                            id$orig_h, fmt("%d", id$orig_p), id$resp_h, fmt("%d", id$resp_p),
	                            conn_log$helo, conn_log$msg_id, conn_log$in_reply_to, 
	                            conn_log$mailfrom, fmt_str_set(conn_log$rcptto, /[\"\'<>]|([[:blank:]].*$)/),
	                            conn_log$date, conn_log$from, conn_log$reply_to, fmt_str_set(conn_log$to, /[\"\']/),
	                            conn_log$last_reply, forward_path);
	}

event smtp_reply(c: connection, is_orig: bool, code: count, cmd: string,
                 msg: string, cont_resp: bool)
	{
	local id = c$id;
	# This continually overwrites, but we want the last reply, so this actually works fine.
	if ( code >= 400 && id in conn_info )
		{
		conn_info[id]$last_reply = fmt("%d %s", code, msg);

		# If a local MTA receives a message from a remote host telling it that it's on a block list, raise a notice.
		if ( smtp_bl_error_messages in msg && is_local_addr(c$id$orig_h) )
			{
			local text_ip = sub(msg, /^.*ip=/, "");
			text_ip = sub(text_ip, /[[:blank:]].*/, "");
			local note = SMTP_BL_Error_Message;
			if ( is_valid_ip(text_ip) && to_addr(text_ip) == c$id$orig_h )
				note = SMTP_BL_Blocked_Host;
			
			NOTICE([$note=note, 
			        $conn=c, 
			        $msg=fmt("%s received an error message mentioning an SMTP block list", c$id$orig_h),
			        $sub=fmt("Remote host said: %s", msg)]);
			}
		}
	}

event smtp_request(c: connection, is_orig: bool, command: string, arg: string) &priority=-5
	{
	local id = c$id;
	if ( id in smtp_sessions )
		{
		if ( id !in conn_info )
			conn_info[id] = default_session_info();
		local conn_log = conn_info[id];
		
		if ( /^([hH]|[eE]){2}[lL][oO]/ in command )
			conn_log$helo = arg;
		
		if ( /^[rR][cC][pP][tT]/ in command && /^[tT][oO]:/ in arg )
			add conn_log$rcptto[split1(arg, /:[[:blank:]]*/)[2]];
		
		if ( /^[mM][aA][iI][lL]/ in command && /^[fF][rR][oO][mM]:/ in arg )
			{
			local partially_done = split1(arg, /:[[:blank:]]*/)[2];
			conn_log$mailfrom = split1(partially_done, /[[:blank:]]/)[1];
			}
		}
	}

event smtp_data(c: connection, is_orig: bool, data: string) &priority=-5
	{
	local id = c$id;
	if ( id !in conn_info )
	  	return;

	local conn_log = conn_info[id];
	if ( /^[mM][eE][sS][sS][aA][gG][eE]-[iI][dD]:[[:blank:]]/ in data )
		conn_log$msg_id = split1(data, /:[[:blank:]]*/)[2];

	if ( /^[iI][nN]-[rR][eE][pP][lL][yY]-[tT][oO]:[[:blank:]]/ in data )
		conn_log$in_reply_to = split1(data, /:[[:blank:]]*/)[2];
	
	if ( /^[dD][aA][tT][eE]:[[:blank:]]/ in data )
		conn_log$date = split1(data, /:[[:blank:]]*/)[2];

	if ( /^[fF][rR][oO][mM]:[[:blank:]]/ in data )
		conn_log$from = split1(data, /:[[:blank:]]*/)[2];
	
	if ( /^[tT][oO]:[[:blank:]]/ in data )
		add conn_log$to[split1(data, /:[[:blank:]]*/)[2]];

	if ( /^[rR][eE][pP][lL][yY]-[tT][oO]:[[:blank:]]/ in data )
		conn_log$reply_to = split1(data, /:[[:blank:]]*/)[2];
	}

event connection_finished(c: connection) &priority=5
	{
	if ( c$id in conn_info )
		end_smtp_extended_logging(c$id);
	}

event connection_state_remove(c: connection) &priority=5
	{
	if ( c$id in conn_info )
		end_smtp_extended_logging(c$id);
	}
