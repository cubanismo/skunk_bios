# Build with high verbosity
V ?= 1
ALIGN=p
include $(JAGSDK)/tools/build/jagdefs.mk

#====================================================================
#       Custom Link flags
#====================================================================

jagmand.cof: STADDR = 80000
jagmand.cof: BSSADDR = 4000
jagbjl.cof: STADDR = 1400

# Output a symbol map
#jagmand.cof: LINKFLAGS += -m  -l

#====================================================================
#       Custom Assembly flags
#====================================================================

# Produce an assembly listing after processing input.
#ASMFLAGS += -llist.txt

#====================================================================
#       Build Flavors
#====================================================================

# Uncomment this to build a no-verify version of the BIOS. Can be
# used to force a BIOS on a board detected as incompatible, or to
# unbrick a board with a corrupted BIOS. Should NOT be needed for
# bootstrapping a new board, as the flash code detects that case
# unless the flash chip soldered on your blank board didn't come
# erased and happens to contain the skunk BIOS magic numbers in just
# the right locations somehow.
#ASMFLAGS += -dNO_VERIFY

# If bootstrapping a bare board using bjlSkunkFlash, the BIOS flash
# will hang at a black screen unless you also connect the jcp console
# after reaching said black screen, or build without skunk console
# support. I recommend the latter. Uncomment this line to build
# without console support.
#
# Never uncomment this when building a BIOS for inclusion in jcp.
#ASMFLAGS += -dNO_CONSOLE

# BIOS version to build. Must be 1, 3, 4, or 5, corresponding to the
# skunkboard PCB revision(s) and feature levels being targeted, as
# described below.
#
# Version 1 only works on Revision 1 boards. I don't know if the BIOS
# produced with this option actually works on Revision 1 boards, as I
# don't have one to test on. The source seems to hint it doesn't
# support producing Rev1-compatible BIOSes anymore, but also still had
# some ifdef logic in place to support them. Feel free to # give it a
# try if you have such a board and know what you're doing.
#
# Version 3 works with Revision 2, and 4 boards as well. It will also
# technically work on Revision 5 boards in a pinch, but the EEPROMs
# won't work on these boards with this BIOS because the GPIOs that
# select which EEPROM chip to enable will be floating, with the most
# likely result being neither works.
#
# Version 4 is for Revsion 5+ boards with two serial EEPROMs. It
# properly initializes the GPIO lines to default to the 128B EEPROM,
# and is otherwise identical to Version 3. A later minor update to
# this version should allow selecting between each EEPROM using the
# D-pad left/right buttons before booting a flash bank or uploading
# code via jcp. This version should work fine on any Revision 2+
# board, but has no benefit on boards prior to Revision 5.
#
# Version 5 is for Revision 5+ boards as well and will feature
# improved Serial EEPROM selection management (Associating persistent
# defaults with each bank, hopefully saving/restoring for each bank as
# well).
ASMFLAGS += -DBIOS_MAJOR_VERSION=4

#====================================================================
#       EXECUTABLES
#====================================================================

OBJS = startup.o startbjl.o
PROGS = jagmand.cof jagbjl.cof

include $(JAGSDK)/jaguar/skunk/skunk.mk

jagmand.cof: startup.o skunk.o
	$(LINK) $(LINKFLAGS) -o $@ $^
	
jagbjl.cof: startbjl.o
	$(LINK) $(LINKFLAGS) -o $@ $^

include $(JAGSDK)/tools/build/jagrules.mk
