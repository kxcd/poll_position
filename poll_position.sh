#!/bin/bash
#set -x

VERSION="$0 v0.0.5"

usage(){
	text="$0 This program will print the expected time to the next masternode payment.\n"
	text+="Edit the MASTERNODES array to place your protx hash in there leaving a space between each one.\n"
	text+="Available options are:\n"
	text+="\t-debug\t:\tto display debug information."
	echo -e "$text"
}

# Parse commandline options and set flags.
while (( $# > 0 ));do
	arg="$1"

	case "$arg" in
		-h|-help|--help)
			usage
			exit 0
			;;
		-debug)
			debug=1
			shift
			;;
		*)
			echo -e "[$$] $VERSION\n[$$] Unknown parameter $1\n[$$] Please check help page with $0 -help" >&2
			exit 1
			;;
	esac
done


# An array of protx hashes.
MASTERNODES=(0062e548ac39d518de7b74b9ea92cf6735a8699a3d70896e533dbb5167aedd0b 0092aa49ee56297a47a5ee6dccca746b58a69f1bf9a24e3e28d9c1ea9bae41ea 00a60e606dd7724391d9f8ee9245b03144921149d6c294439ee81ccdd1de9d2d 00a6aa2d8bc371d4577c887a5c68003b75dba238eebc9c6d76941b1e7b7a4304 fef139ff6fc509529dad0540a48d5b305dc3eb319c7de3afb3ff63f52d838d95 ff00b58e4b281f41d6d87df335ab8e632177c3c2ec57c6e4e0d7f248e0bb9f51 ff09ea3a7ef93a0bf5179cec8eee1271a15afc702902b5d6f5a38331e206d3b0 ff93208c66329768323a47711f7e8c211c8b42dd38b8a2dc36118d1d70fe673e ff93af84ac3f7cd70dc522696e9d012662e00fff403ff78f122e6dbd7a6a4b54 ffa4a74c58aa0002696df1a7d2562b5a36f5116581a0df1a91500a9664985f52 ffa516477af8d6a3cea068a625401415934585f71e6fad72c880ed157da95f92 ffaaf68b98d79e28fd26f9404696385f64d3576af39507adfc295e8037993787)

# Checks that the required software is installed on this machine.
bc -v >/dev/null 2>&1 || progs+=" bc"
jq -V >/dev/null 2>&1 || progs+=" jq"

if [[ -n $progs ]];then
	text="Missing applications on your system, please run\n\n"
	text+="\tsudo apt install $progs\n\nbefore running this program again."
	echo -e "$text" >&2
	exit 1
fi

[[ -n $debug ]]&&{ start_time=$EPOCHSECONDS;echo -n "Fetching protx list..." >&2;}

all_mns_list=$(dash-cli protx list registered 1)
if (( $? != 0 ));then
	echo "Problem running dash-cli, make sure it is in your path and working..."
	exit 1
fi



# A function to print out each MN (protx) in order of next to the be paid (first) to last to be paid at the bottom.
# First column is the line number, the second column is the protxhash, ....
createOrderedPaymentList(){
	while read proTxHash PoSeBanHeight lastPaidHeight PoSeRevivedHeight registeredHeight service PoSePenalty payoutAddress junk;do
		# No need to place banned nodes in the queue, they won't be paid and will re-enter at the rear.
		((PoSeBanHeight!=-1))&&continue;
		# If the lastpaid height is zero, then it is has never been paid, so use the registered height as the payment height.
		((lastPaidHeight==0))&&lastPaidHeight=$registeredHeight
		# If the node has been revived from ban status recently, use that instead of the last paid height, since it lost its spot in the queue.
		((PoSeRevivedHeight>lastPaidHeight))&&lastPaidHeight=$PoSeRevivedHeight
		ip=$(awk -F: '{print $1}' <<< "$service")
		echo "$proTxHash $lastPaidHeight $ip $PoSePenalty $payoutAddress"
	done < <(jq -r '.[]|"\(.proTxHash) \(.state.PoSeBanHeight) \(.state.lastPaidHeight) \(.state.PoSeRevivedHeight) \(.state.registeredHeight) \(.state.service) \(.state.PoSePenalty) \(.state.payoutAddress)"' <<< "$all_mns_list")|\
	sort -n -k2|awk '{print NR " " $0}'
}

[[ -n $debug ]]&&{ echo -en "Done in $((EPOCHSECONDS-start_time)) seconds.\nSorting the list of masternodes..." >&2;start_time=$EPOCHSECONDS;}
orderedPaymentList=$(createOrderedPaymentList)

[[ -n $debug ]]&&{ echo -en "Done in $((EPOCHSECONDS-start_time)) seconds.\nFetching DASH price quote..." >&2;start_time=$EPOCHSECONDS;}
Dash_USD=$(printf '$%0.2f' $(curl -Ls "https://chainz.cryptoid.info/dash/api.dws?q=ticker.usd"))
echo "Dash Price: ${Dash_USD}."
# Block time in minutes.
block_time="2.625"


# A function to format the into human readable units.
# Takes one argument, minutes and prints a text string.
formatTime(){
	minutes="$1"
	result=$(echo "$minutes<245"|bc)
	((result==1))&&{ echo "$minutes minutes";return;}
	result=$(echo "$minutes<(49*60)"|bc)
	((result==1))&&{ hours=$(printf '%0.2f' $(echo "scale=4;$minutes/60"|bc));echo "$hours hours";return;}
	days=$(printf '%0.1f' $(echo "scale=4;$minutes/60/24"|bc))
	echo "$days days"
}

[[ -n $debug ]]&&{ echo -e "Done in $((EPOCHSECONDS-start_time)) seconds.\nPrinting list..." >&2;start_time=$EPOCHSECONDS;}
queue_length=$(wc -l <<< "$orderedPaymentList")
for m in ${MASTERNODES[*]};do

	mn_data=$(grep "$m" <<< "$orderedPaymentList")
	[[ -z "$mn_data" ]] && { echo "MN with ProTxHash = $m was not found on the network!  Check this hash for typo and registration issues and PoSe ban status!";continue;}

	position=$(awk '{print $1}' <<< "$mn_data")

	payoutAddress=$(awk '{print $6}' <<< "$mn_data")
	balance=$(curl -Ls "https://chainz.cryptoid.info/dash/api.dws?q=getbalance&a=$payoutAddress")

	ip=$(awk '{print $4}' <<< "$mn_data")

	poseMessage=
	PoSePenalty=$(awk '{print $5}' <<< "$mn_data")
	((PoSePenalty>0))&&poseMessage="Warning!  This masternode has a PoSe Score of ${PoSePenalty}."

	# Determine the progress completed out of $progressLength
	progressLength=20
	progressMade=$(echo "scale=2;($queue_length-$position)/$queue_length*$progressLength"|bc|awk '{printf("%d\n",$1 + 0.5)}')
	progressRemaining=$((progressLength-progressMade))
	progressBar="["
	for((i=0; i<progressMade; i++));do progressBar+='|';done
	for((i=0; i<progressRemaining; i++));do progressBar+=':';done
	progressBar+="]"

	progressPercent=$(printf '%0.2f' $(echo "scale=4;($queue_length-$position)/$queue_length*100"|bc))

	# When pay in minutes
	timeToReward=$(echo "scale=4;$block_time*$position"|bc)
	timeToReward=$(formatTime "$timeToReward")

	#echo -e "MN ProTxHash (${m:0:4}...${m:60:4}) queue position ${position}/${queue_length}.\tNext payment in ${timeToReward}.\tProgress: $progressBar ${progressPercent}% Balance: $balance Dash 1Dash=$Dash_USD.  $poseMessage"
	str1="MN ProTxHash (${m:0:4}...${m:60:4}) queue position ${position}/${queue_length}."
	str2="Next payment in ${timeToReward}."
	str3="Progress: $progressBar ${progressPercent}%."
	str4="Balance: ${balance}. $poseMessage"
	printf "%-53s %-29s %-41s %s\n" "$str1" "$str2" "$str3" "$str4"
done
[[ -n $debug ]]&&echo "Done in $((EPOCHSECONDS-start_time)) seconds."
:

