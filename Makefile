# Build with high verbosity
V ?= 2
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
