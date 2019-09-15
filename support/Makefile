#
# Make a program to run /usr/local/bin/positionzpp_hook.sh with setuid to root
#

build:
	gcc positionzpp_hook.c -o positionzpp_hook

install: build
	cp positionzpp_hook /opt/positionzpp/
	chmod 4755 /opt/positionzpp/positionzpp_hook
