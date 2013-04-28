#!/bin/sh
#
# git-sfe.sh: submodule foreach with option to include supermodule
#
# Lots of things copied and pasted from git-submodule.sh
# TODO Add in other updates to git-submodule-foreach

dashless=$(basename "$0" | sed -e 's/-/ /')
USAGE="foreach [-l | --list LIST] [-c | --constrain] [-t | --top-level] [-r | --recursive] [-p | --post-order] <command>
	or: $dashless sync
	or: $dashless womp [FOREACH_FLAGS]
	or: $dashless branch [FOREACH_FLAGS] [write | checkout]"
OPTIONS_SPEC=
. git-sh-setup
. git-sh-i18n
. git-parse-remote
require_work_tree

# http://stackoverflow.com/questions/171550/find-out-which-remote-branch-a-local-branch-is-tracking
# git name-rev --name-only HEAD

set -u -e

#
# Get submodule info for registered submodules
# $@ = path to limit submodule list
#
module_list()
{
	(
		git ls-files --error-unmatch --stage -- "$@" ||
		echo "unmatched pathspec exists"
	) |
	perl -e '
	my %unmerged = ();
	my ($null_sha1) = ("0" x 40);
	my @out = ();
	my $unmatched = 0;
	while (<STDIN>) {
		if (/^unmatched pathspec/) {
			$unmatched = 1;
			next;
		}
		chomp;
		my ($mode, $sha1, $stage, $path) =
			/^([0-7]+) ([0-9a-f]{40}) ([0-3])\t(.*)$/;
		next unless $mode eq "160000";
		if ($stage ne "0") {
			if (!$unmerged{$path}++) {
				push @out, "$mode $null_sha1 U\t$path\n";
			}
			next;
		}
		push @out, "$_\n";
	}
	if ($unmatched) {
		print "#unmatched\n";
	} else {
		print for (@out);
	}
	'
}

die_if_unmatched ()
{
	if test "$1" = "#unmatched"
	then
		exit 1
	fi
}

#
# Map submodule path to submodule name
#
# $1 = path
#
module_name()
{
	# Do we have "submodule.<something>.path = $1" defined in .gitmodules file?
	sm_path="$1"
	re=$(printf '%s\n' "$1" | sed -e 's/[].[^$\\*]/\\&/g')
	name=$( git config -f .gitmodules --get-regexp '^submodule\..*\.path$' |
		sed -n -e 's|^submodule\.\(.*\)\.path '"$re"'$|\1|p' )
	test -z "$name" &&
	die "$(eval_gettext "No submodule mapping found in .gitmodules for path '\$sm_path'")"
	echo "$name"
}

# TODO Add below functionality, for syncing with other computers via git-daemon
# git sfer 'echo $(cd $toplevel && cd $(git rev-parse --git-dir) && pwd)/modules/$path'

cmd_sync()
{
	die "Not implemented. Use git-submodule sync"
}

cmd_foreach()
{
	# parse $args after "submodule ... foreach".
	recursive=
	post_order=
	include_super=
	constrain=
	silent=
	list=
	recurse_flags=
	while test $# -ne 0
	do
		case "$1" in
		-q|--quiet)
			GIT_QUIET=1
			;;
		-r|--recursive)
			recursive=1
			recurse_flags="$recurse_flags --recursive"
			;;
		-p|--post-order)
			post_order=1
			recurse_flags="$recurse_flags --post-order"
			;;
		-c|--constrain)
			constrain=1
			recurse_flags="$recurse_flags --constrain"
			;;
		-t|--top-level)
			include_super=1
			;;
		-l|--list)
			list=$2
			shift
			;;
		-s|--silent)
			silent=1
			recurse_flags="$recurse_flags --silent"
			;;
		-*)
			usage
			;;
		*)
			break
			;;
		esac
		shift
	done

	toplevel=$(pwd)

	# dup stdin so that it can be restored when running the external
	# command in the subshell (and a recursive call to this function)
	exec 3<&0

	# For supermodule
	name=$(basename $toplevel)
	# This is absolute... Is that a good idea?
	path=$toplevel

	super_eval()
	{
		verb=$1
		shift
		test -z "$silent" && say "$(eval_gettext "$verb supermodule '$name'")"
		( eval "$@" ) || die "Stopping at supermodule; script returned non-zero status."
	}

	if test -n "$include_super" -a -z "$post_order"
	then
		super_eval Entering "$@"
	fi
	
	if test -n "$constrain"
	then
		if test -z "$list"
		then
			list=$(git config scm.focusGroup)
		else
			echo "Note: List set for parent, only constraining on submodules"
		fi
	fi

	test -z "${prefix+D}" && prefix=

	module_list $list |
	while read mode sha1 stage sm_path
	do
		die_if_unmatched "$mode"
		if test -e "$sm_path"/.git
		then
			enter_msg="$(eval_gettext "Entering '\$prefix\$sm_path'")"
			exit_msg="$(eval_gettext "Leaving '\$prefix\$sm_path'")"
			die_msg="$(eval_gettext "Stopping at '\$sm_path'; script returned non-zero status.")"
			(
				name=$(module_name "$sm_path")
				prefix="$prefix$sm_path/"
				clear_local_git_env
				# we make $path available to scripts ...
				path=$sm_path
				cd "$sm_path" &&
				if test -z "$post_order"
				then
					test -z "$silent" && say "$enter_msg"
					eval "$@" || exit 1
				fi &&
				if test -n "$recursive"
				then
					list=
					cmd_foreach $recurse_flags "$@" || exit 1
				fi &&
				if test -n "$post_order"
				then
					test -z "$silent" && say "$exit_msg"
					eval "$@" || exit 1
				fi
			) <&3 3<&- || die "$die_msg"
		fi
	done || exit 1

	if test -n "$include_super" -a -n "$post_order"
	then
		super_eval Leaving "$@"
	fi
}

branch_get() {
	git rev-parse --abbrev-ref HEAD
}
branch_set_upstream() {
	# For Git < 1.8
	branch=$(branch_get)
	git branch --set-upstream $branch $remote/$branch
}

branch_iter_write() {
	branch=$(branch_get)
	git config -f $toplevel/.gitmodules submodule.$name.branch $branch
}
branch_iter_checkout() {
	if branch=$(git config -f $toplevel/.gitmodules submodule.$name.branch 2>/dev/null)
	then
		git checkout $branch
	fi
}
cmd_branch()
{
	local foreach_flags= command=
	while test $# -gt 0
	do
		case $1 in
			-s|-c|-r)
				foreach_flags="$foreach_flags $1"
				;;
			*)
				break
				;;
		esac
		shift
	done
	test $# -eq 0 && usage
	case $1 in
		write | checkout)
			command=$1
			;;
		*)
			usage
			;;
	esac
	cmd_foreach $foreach_flags branch_iter_${command}
}

cmd_womp()
{
	# How to get current remote?
	local clean= set_upstream= no_pull= recursive= force= sync=1
	local remote=origin
	local foreach_flags=
	while test $# -gt 0
	do
		case $1 in
			--remote)
				remote=$2
				shift
				;;
			--clean)
				clean=1
				;;
			--no-sync)
				sync=
				;;
			-u|--set-upstream)
				set_upstream=1
				;;
			-n|--no-pull)
				no_pull=1
				;;
			-f|--force)
				echo "WARNING: This will do a HARD reset on all of your branches to your remote."
				echo "Are you sure you want to continue? [Y/n]"
				read choice
				case "$choice" in
					Y|y)
						force=1
						;;
					*)
						die "Aborting"
						;;
				esac
				;;
			# foreach flags
			-l)
				# Escaping woes
				foreach_flags="$foreach_flags $1 '$2'"
				;;
			-s|-c|-r)
				foreach_flags="$foreach_flags $1"
				;;
			*)
				break
				;;
		esac
		shift
	done

	womp_iter() {
		git fetch --no-recurse-submodules $remote
		test -n "$top_level" && branch_iter_checkout
		branch=$(branch_get)
		if test -z "$force"
		then
			git merge $remote/$branch
		else
			git checkout -fB $branch $remote/$branch
		fi
		test -n "$clean" && git clean -fd
		test -n "$set_upstream" && branch_set_upstream
	}

	# Do top-level first
	top_level=
	womp_iter

	git submodule init
	test -n "$sync" && git submodule sync
	git submodule update || echo "Update failed... Still continuing"

	# Now do it
	cmd_foreach -p $foreach_flags womp_iter
}

command=
while test $# != 0 && test -z "$command"
do
	case "$1" in
	foreach | sync | womp | branch)
		command=$1
		;;
	*)
		usage
		;;
	esac
	shift
done
test -z "$command" && usage

"cmd_$command" "$@"