# load environment variables from .env
source .env

# set env variables
export ADDRESSES_FILE=./deployments/goerli.json
export RPC_URL=$RPC_URL_GOERLI

# load common utilities
. $(dirname $0)/common.sh

# deploy contracts
bagholder_address=$(deploy Bagholder $PROTOCOL_FEE)
echo "Bagholder=$bagholder_address"

send $bagholder_address "transferOwnership(address,bool,bool)" $OWNER true false
echo "BagholderOwner=$OWNER"