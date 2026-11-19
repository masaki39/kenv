#!/bin/zsh -f
# Tests for kenv. Run: zsh tests/test.zsh
#
# Uses only tests/fake-security (via KENV_SECURITY) and a temporary directory. It never
# touches a real keychain: HOME and KENV_KEYCHAIN point into the temp dir, and a
# `security` that fails loudly is put first on PATH to catch any call that escapes.

emulate zsh
setopt no_unset

ROOT=${0:A:h:h}
KENV=$ROOT/bin/kenv
T=$(mktemp -d "${TMPDIR:-/tmp}/kenv-test.XXXXXX") || exit 1
trap 'rm -rf -- $T' EXIT

mkdir -p $T/bin $T/sec $T/home/Library/Keychains
print -r -- "#!/bin/sh
touch '$T/real-security-called'; echo 'tests: real security called' >&2; exit 99" > $T/bin/security
chmod +x $T/bin/security

export PATH=$T/bin:$PATH HOME=$T/home FAKE_SEC_DIR=$T/sec
export KENV_SECURITY=$ROOT/tests/fake-security
export KENV_KEYCHAIN=$T/home/Library/Keychains/kenv.keychain-db
unset KENV_LOCK_AFTER
KC=$KENV_KEYCHAIN
LOGIN=$T/home/Library/Keychains/login.keychain-db

integer pass=0 fail=0
OUT= ERR= ST=0

# k [args...]: run kenv with stdin from /dev/null; sets OUT, ERR, ST
k() { OUT=$("$KENV" "$@" </dev/null 2>$T/err); ST=$?; ERR=$(<$T/err) }
# kin VALUE [args...]: same, with VALUE on stdin
kin() { local v=$1; shift; OUT=$(print -rn -- "$v" | "$KENV" "$@" 2>$T/err); ST=$?; ERR=$(<$T/err) }
# setk KEY VALUE: store a value, failing the test on error
setk() { kin "$2" set "$1"; is "set $1" 0 }

ok() {  # ok NAME CONDITION
	if eval "$2"; then
		(( pass++ ))
	else
		(( fail++ ))
		print -r -- "FAIL: $1   [$2]"
		print -r -- "  status=$ST"
		print -r -- "  stdout=${(q+)OUT[1,300]}"
		print -r -- "  stderr=${(q+)ERR}"
	fi
}
EXP=
is() { ok "$1 (status $2)" "(( ST == $2 ))" }                # is NAME STATUS
out() { EXP=$2; ok "$1 (stdout)" '[[ $OUT == $EXP ]]' }       # out NAME TEXT
err_has() { EXP=$2; ok "$1 (stderr)" '[[ $ERR == *$EXP* ]]' } # err_has NAME SUBSTRING
# put an item straight into the fake keychain, bypassing kenv's checks
inject() { print -r -- "add-generic-password -s \"kenv:$1\" -w \"$2\"" | $KENV_SECURITY -i }

# --- help / version ----------------------------------------------------------------
k help;      is help 0; H=$OUT
ok 'help starts with usage' '[[ $H == "usage: kenv <command>"* ]]'
ok 'help is 15 lines or fewer' '(( ${#${(f)H}} <= 15 ))'
ok 'help mentions KENV_KEYCHAIN' '[[ $H == *KENV_KEYCHAIN* ]]'
ok 'help mentions how to change the timeout' '[[ $H == *"KENV_LOCK_AFTER=600 kenv init"* ]]'
k -h;        is -h 0;     out -h "$H"
k --help;    is --help 0; out --help "$H"
k version;   is version 0;   out version 'kenv 0.1.1'
k -v;        is -v 0;        out -v 'kenv 0.1.1'
k --version; is --version 0; out --version 'kenv 0.1.1'
k;           is 'no args' 2; err_has 'no args' 'usage: kenv'
k bogus;     is 'unknown command' 2; err_has 'unknown command' 'kenv: unknown command: bogus'
ok 'unknown command also shows help' '[[ $ERR == *"usage: kenv <command>"* ]]'
k; ok 'no args: no unknown-command line' '[[ $ERR != *"unknown command"* ]]' 

for c in init set get rm ls run lock unlock status; do
	for f in -h --help; do
		k $c $f; is "$c $f" 0
		ok "$c $f shows its usage" '[[ $OUT == "usage: kenv $c"* ]]'
		ok "$c $f is 1-2 lines" '(( ${#${(f)OUT}} <= 2 ))'
	done
done
k set; is 'set without key' 2; err_has 'set without key' 'usage: kenv set <KEY>'

# --- before init -------------------------------------------------------------------
k get FOO;  is 'get before init' 1; err_has 'get before init' 'keychain not found'
k status;   is 'status before init' 1; ok 'status before init' '[[ $OUT == *"not created"* ]]'
KENV_KEYCHAIN=rel.keychain-db k ls; is 'relative KENV_KEYCHAIN' 2
err_has 'relative KENV_KEYCHAIN' 'absolute path'

# --- init (on an existing keychain file; creating one needs a TTY) ------------------
touch $KC $LOGIN
# the old-style name (login.keychain, whose -db file exists) must be kept,
# a missing file and kenv's own keychain must be dropped
print -rl -- ${LOGIN%-db} $T/gone.keychain-db $KC > $T/sec/searchlist
k init; is init 0
ok 'init keeps old-style login entry, drops missing and kenv' '[[ $(<$T/sec/searchlist) == ${LOGIN%-db} ]]'
ok 'init default timeout 300' '[[ $(<$T/sec/timeout) == 300 ]]'
KENV_LOCK_AFTER=600 k init; is 'init with KENV_LOCK_AFTER' 0
ok 'KENV_LOCK_AFTER applied' '[[ $(<$T/sec/timeout) == 600 ]]'
KENV_LOCK_AFTER=abc k init; is 'invalid KENV_LOCK_AFTER' 2
KENV_LOCK_AFTER=0 k init;   is 'zero KENV_LOCK_AFTER' 2
k init extra; is 'init with argument' 2

# --- status ------------------------------------------------------------------------
k status; is status 0
ok 'status path uses ~' '[[ $OUT == *"keychain: ~/Library/Keychains/kenv.keychain-db"* ]]'
ok 'status unlocked' '[[ $OUT == *"state:    unlocked"* ]]'
ok 'status shows timeout' '[[ $OUT == *"lock:     after 600s idle and on sleep"* ]]'
ok 'status: no search-list warning' '[[ $OUT != *warning* ]]'
print -rl -- $LOGIN $KC > $T/sec/searchlist
k status; ok 'status warns when in search list' '[[ $OUT == *"in the search list"* ]]'
print -rl -- $LOGIN > $T/sec/searchlist
k status extra; is 'status with argument' 2

# --- ls on an empty keychain (N1) ---------------------------------------------------
k ls;    is 'ls empty' 0;    out 'ls empty' ''
k ls -a; is 'ls -a empty' 0; out 'ls -a empty' ''

# --- set / get ---------------------------------------------------------------------
setk FOOBAR one
# I4: with exactly one stored key, a substring must still be "not stored"
k get FOO; is 'get substring of the only key' 1; err_has 'get substring' 'not stored'
k get OBA; is 'get inner substring' 1; err_has 'get inner substring' 'not stored'

setk FOO bar
k get FOO; is get 0; out get bar
OUT=$("$KENV" get FOO; print x); ok 'get prints a trailing newline' '[[ $OUT == $'"'"'bar\nx'"'"' ]]'

V=$'a"b\\c\'d $x `y` %s p[x] <1-5> (a|b) *~'
setk SPECIAL "$V"
k get SPECIAL; is 'get special chars' 0; out 'special chars round-trip' "$V"
# anything but printable ASCII is refused before writing (macOS would return it as hex)
for v in $'tab\there' 'café' $'bell\a' 'キー'; do
	kin "$v" set NONASCII; is "non-printable value ${(q+)v}" 1
	err_has "non-printable value ${(q+)v}" 'printable ASCII'
done
k get NONASCII; is 'refused value was not written' 1
# security -i cannot take long lines: too-long values are refused before writing
A1K=$(printf "a%.0s" {1..1024}); A2K=$A1K$A1K
setk LONG keep
kin "$A1K" set LONG; is 'value of 1024 chars' 0
kin "$A2K" set LONG; is 'value of 2048 chars' 1; err_has 'too long value' 'value too long'
k get LONG; out 'too long value was not written' "$A1K"
k rm LONG; is 'rm LONG' 0
V2='q"uo\te $HOME'
setk QUOTE "$V2"
k get QUOTE; out 'quotes and backslashes round-trip' "$V2"
setk FOO baz; k get FOO; out 'set overwrites' baz

kin '' set EMPTY;           is 'empty value' 1;   err_has 'empty value' 'empty value'
kin $'a\nb' set NL;         is 'newline in value' 1
kin x set 1BAD;             is 'invalid key' 2;   err_has 'invalid key' 'invalid key name'
kin x set 'a/b/C';          is 'nested project' 2
for n in PATH path HOME IFS LANG TERM status argv _kenv_x projA/HOME projA/_kenv_v; do
	kin x set $n; is "reserved name $n" 2; err_has "reserved name $n" 'reserved name'
done
# get / rm check only the syntax, so a key stored under a reserved name stays reachable
inject RSV/PATH x; inject IFS y
k get PATH; is 'get reserved name: syntax only' 1; err_has 'get reserved name' 'not stored'
k get IFS;  is 'get stored reserved name' 0; out 'get stored reserved name' y
k rm IFS;   is 'rm stored reserved name' 0
k rm RSV/PATH; is 'rm stored reserved project key' 0

# --- projects and ls ---------------------------------------------------------------
setk projA/X x1
setk projA/Y y1
setk projB/Z z1
k ls;  is ls 0
out ls $'FOO\nFOOBAR\nQUOTE\nSPECIAL\nprojA/  (2 keys)\nprojB/  (1 key)'
k ls projA; out 'ls projA' $'X\nY'
k ls -a;    ok 'ls -a lists project keys' '[[ $OUT == *projA/X* && $OUT == *projB/Z* ]]'
k ls nope;  is 'ls missing project' 1
k ls 'a b'; is 'ls invalid project' 2
k ls a b;   is 'ls two args' 2

# --- run ---------------------------------------------------------------------------
k run FOO -- /usr/bin/env; is 'run' 0
ok 'run exports the key' '[[ ${(f)OUT} == *FOO=baz* ]]'
ok 'run exports nothing of kenv' '[[ $OUT != *_kenv_* ]]'
ok 'run does not export others' '[[ $OUT != *FOOBAR=* ]]'
k run -p projA FOO -- /usr/bin/env; is 'run -p' 0
ok 'run -p exports project keys by NAME' '(( ${${(f)OUT}[(Ie)X=x1]} && ${${(f)OUT}[(Ie)Y=y1]} && ${${(f)OUT}[(Ie)FOO=baz]} ))'
ok 'run -p does not export other projects' '[[ $OUT != *Z=z1* ]]'
k run -pprojB -- /usr/bin/env; ok 'run -pPROJ' '(( ${${(f)OUT}[(Ie)Z=z1]} ))'
k run -p projA -p projB -- /usr/bin/env; ok 'run two projects' '(( ${${(f)OUT}[(Ie)Z=z1]} && ${${(f)OUT}[(Ie)X=x1]} ))'
k run FOO -- /bin/sh -c 'exit 7'; is 'run passes the exit status' 7

k run FOO;                  is 'run without --' 2
k run -- /usr/bin/env;      is 'run without keys' 2
k run FOO --;               is 'run without command' 2
k run -x FOO -- true;       is 'run unknown option' 2
k run projA/X -- true;      is 'run with PROJ/NAME' 2; err_has 'run with PROJ/NAME' '-p PROJ'
k run PATH -- true;         is 'run reserved name' 2
k run NOPE -- true;         is 'run missing key' 1; err_has 'run missing key' 'not stored'
k run -p nope -- true;      is 'run missing project' 1
k run FOO 1BAD -- true;     is 'run validates names before reading' 2

# N10: a global key overrides a project key of the same name, with a warning
setk X global
k run -p projA X -- /usr/bin/env; is 'run override' 0
ok 'global key wins' '(( ${${(f)OUT}[(Ie)X=global]} ))'
err_has 'override warning' 'overridden'

# C1: key names that used to collide with kenv's own variables
for n in v k p reply keys projs USER cmd info list match MATCH mbegin mend MBEGIN MEND REPLY KC PREFIX; do
	setk c1/$n "val-$n"
	setk $n "g-$n"
done
k run -p c1 -- /usr/bin/env; is 'C1 project keys' 0
for n in v k p reply keys projs USER cmd info list match MATCH mbegin mend MBEGIN MEND REPLY KC PREFIX; do
	ok "C1 project key $n" '(( ${${(f)OUT}[(Ie)$n=val-$n]} ))'
done
k run v k p reply keys projs USER cmd info list match MATCH mbegin mend MBEGIN MEND REPLY KC PREFIX -- /usr/bin/env
is 'C1 global keys' 0
for n in v k p reply keys projs USER cmd info list match MATCH mbegin mend MBEGIN MEND REPLY KC PREFIX; do
	ok "C1 global key $n" '(( ${${(f)OUT}[(Ie)$n=g-$n]} ))'
done
# integer-typed MBEGIN/MEND (set by =~): values must not be evaluated as arithmetic
for n v in MBEGIN 0x10 MEND 1+1 mbegin '7*6' mend val; do
	setk c3/$n "$v"
	setk $n "$v"
done
k run -p c3 -- /usr/bin/env; is 'C1 numeric-like project values' 0
ok 'C1 MBEGIN=0x10 (project)' '(( ${${(f)OUT}[(Ie)MBEGIN=0x10]} && ${${(f)OUT}[(Ie)MEND=1+1]} && ${${(f)OUT}[(Ie)mbegin=7*6]} && ${${(f)OUT}[(Ie)mend=val]} ))'
k run MBEGIN MEND mbegin mend -- /usr/bin/env; is 'C1 numeric-like global values' 0
ok 'C1 MBEGIN=0x10 (global)' '(( ${${(f)OUT}[(Ie)MBEGIN=0x10]} && ${${(f)OUT}[(Ie)MEND=1+1]} && ${${(f)OUT}[(Ie)mbegin=7*6]} && ${${(f)OUT}[(Ie)mend=val]} ))'
ok 'C1 values not leaked to stderr' '[[ $ERR != *0x10* && $ERR != *val* ]]'
# a reserved name stored by other means is refused by run before anything is exported
inject c2/PATH /evil
inject c2/OK ok
k run -p c2 -- /usr/bin/env; is 'C1 stored reserved name' 2; err_has 'C1 stored reserved name' 'reserved name: PATH'
print -r -- 'delete-generic-password -s "kenv:c2/PATH"' | $KENV_SECURITY -i

# --- rm ----------------------------------------------------------------------------
k rm FOO;      is rm 0
k get FOO;     is 'get after rm' 1
k rm FOO;      is 'rm missing' 1; err_has 'rm missing' 'cannot delete FOO'
k rm projB/;   is 'rm project' 0
k ls projB;    is 'project gone' 1
k rm 'bad name/'; is 'rm invalid project' 2
k rm 1BAD;     is 'rm invalid key' 2

# --- locked keychain ---------------------------------------------------------------
k lock;        is lock 0
k status;      ok 'status locked' '[[ $OUT == *"state:    locked"* ]]'
k get FOOBAR;  is 'get while locked' 1; err_has 'get while locked' 'keychain is locked'
k run FOOBAR -- true; is 'run while locked' 1; err_has 'run while locked' 'keychain is locked'
kin x set NEWKEY; is 'set while locked' 1; err_has 'set while locked' 'keychain is locked'
k ls;          is 'ls works while locked' 0
k lock extra;  is 'lock with argument' 2
k unlock;      is unlock 0
k get FOOBAR;  out 'get after unlock' one

# --- listing failure (N6) ----------------------------------------------------------
touch $T/sec/dump-fails
k ls; is 'ls when listing fails' 1; err_has 'ls when listing fails' 'cannot list'
rm -f $T/sec/dump-fails

# --- safety ------------------------------------------------------------------------
ok 'real security was never called' '[[ ! -e $T/real-security-called ]]'
ok 'fake security was used' '[[ -s $T/sec/log ]]'

print -r -- "$pass passed, $fail failed"
(( fail == 0 ))
