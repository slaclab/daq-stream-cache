# Load RUCKUS library
source -quiet $::env(RUCKUS_DIR)/vivado_proc.tcl

# Check for submodule tagging
if { [info exists ::env(OVERRIDE_SUBMODULE_LOCKS)] != 1 || $::env(OVERRIDE_SUBMODULE_LOCKS) == 0 } {
   if { [SubmoduleCheck {ruckus} {2.9.0} ] < 0 } {exit -1}
} else {
   puts "\n\n*********************************************************"
   puts "OVERRIDE_SUBMODULE_LOCKS != 0"
   puts "Ignoring the submodule locks in surf/ruckus.tcl"
   puts "*********************************************************\n\n"
}

# Load Source Code
loadSource -lib daq_stream_cache -dir "$::DIR_PATH/rtl"

# Load xci files
loadIpCore -path "$::DIR_PATH/coregen/XilinxKcu1500Mig0Core.xci"
loadIpCore -path "$::DIR_PATH/coregen/XilinxKcu1500Mig1Core.xci"
loadIpCore -path "$::DIR_PATH/coregen/MigXbarV3.xci"
loadIpCore -path "$::DIR_PATH/coregen/ila_0.xci"

loadConstraints -path "$::DIR_PATH/coregen/XilinxKcu1500Mig0.xdc"
loadConstraints -path "$::DIR_PATH/coregen/XilinxKcu1500Mig1.xdc"
