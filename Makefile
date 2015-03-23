.SUFFIXES: .erl .beam

.erl.beam:
	erlc -W $<

MODS = client parser window server

all: compile

compile: ${MODS:%=%.beam}

clean:
	rm -rf *.beam erl_crash.dump
server:
	erl -sname server -setcookie abc
client1:
	erl -sname client1 -setcookie abc
client2:
	erl -sname client2 -setcookie abc
