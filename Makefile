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

# Produce an assembly listing after processing input.
#ASMFLAGS += -llist.txt

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
