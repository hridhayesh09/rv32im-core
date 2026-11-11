# Print the slowest setup paths: quartus_sta -t worst_paths.tcl [revision] (in fpga/de10lite)
set rev [expr {[llength $argv] > 0 ? [lindex $argv 0] : "rv32im_soc"}]
project_open rv32im_soc -revision $rev
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 8 -detail summary -file output_files/worst_paths.txt
report_timing -setup -npaths 1 -detail full_path -file output_files/worst_path_detail.txt
project_close
