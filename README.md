# catForth

FreeBSD/amd64 ITC Forth

Work in progress

## Current status

````
$ ./foo
10 10 + HERE !
HERE @ SC_EXIT
$ echo $?
20
````

where SC_EXIT is the exit syscall
