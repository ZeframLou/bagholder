ADDRESSES_FILE=${ADDRESSES_FILE:-./deployments/output.json}
RPC_URL=${RPC_URL:-http://localhost:8545}

deploy() {
	NAME=$1
	ARGS=${@:2}

	ADDRESS=$(forge create $NAME --json --force --rpc-url=$RPC_URL --private-key=$PRIVATE_KEY --constructor-args $ARGS | jq -r '.deployedTo')
	saveContract "$NAME" "$ADDRESS"
	echo "$ADDRESS"
}

deployNoArgs() {
	NAME=$1

	ADDRESS=$(forge create $NAME --json --force --rpc-url=$RPC_URL --private-key=$PRIVATE_KEY | jq -r '.deployedTo')
	saveContract "$NAME" "$ADDRESS"
	echo "$ADDRESS"
}

saveContract() {
	# create an empty json if it does not exist
	if [[ ! -e $ADDRESSES_FILE ]]; then
		echo "{}" >"$ADDRESSES_FILE"
	fi
	result=$(cat "$ADDRESSES_FILE" | jq -r ". + {\"$1\": \"$2\"}")
	printf %s "$result" >"$ADDRESSES_FILE"
}

send() {
	TO=$1
	SIG=$2
	ARGS=${@:3}

	cast send --rpc-url=$RPC_URL --private-key=$PRIVATE_KEY $TO $SIG $ARGS
}