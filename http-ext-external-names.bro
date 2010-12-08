@load http-ext

module HTTP;

export {
    const local_domains = /(^|\.)example\.com($|:)/ &redef;

    # in site policy, redef HTTP::ignore_external_addr += {1.2.3.4};
    #                 redef HTTP::ignore_external_host += {"www.foo.com"};


    global ignore_external_addr: set[addr]   &redef;
    global ignore_external_host: set[string] &redef;

    #maybe this should be two tables for mapping addr -> string and string -> addr?
    global external_names: set[addr, string] &create_expire=1day &synchronized &persistent;
}

event bro_init() &priority=10
{
    LOG::create_logs("http-external-names", AllHosts, F, T);
    LOG::define_header("http-external-names", cat_sep("\t", "\\N", "ts", "host", "hostname"));
}


event http_ext(id: conn_id, si: http_ext_session_info) &priority=1
{
    if(id$resp_h in ignore_external_addr || si$host in ignore_external_host)
        return;

    if(is_local_addr(id$resp_h) && local_domains !in si$host) {
        si$force_log = T;
        add si$force_log_reasons["external_name"];

        if([id$resp_h, si$host] !in external_names){
            add external_names[id$resp_h, si$host];
            local log = LOG::get_file_by_addr("http-external-names", id$resp_h, T);
            print log, cat_sep("\t", "\\N", si$start_time, id$resp_h, si$host);
        }
    }
}