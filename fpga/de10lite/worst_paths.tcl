# Print the slowest setup paths: quartus_sta -t worst_paths.tcl (in fpga/de10lite)
project_open rv32im_soc
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 5 -detail summary -file output_files/worst_paths.txt
project_close
