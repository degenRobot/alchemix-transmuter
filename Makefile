-include .env

# deps
update:; forge update
build  :; forge build
size  :; forge build --sizes

# storage inspection
inspect :; forge inspect ${contract} storage-layout --pretty

FORK_URL := ${ETH_RPC_URL} 
# FORK_URL := ${ARBI_RPC_URL} 
# FORK_URL := ${OPTIMISM_RPC_URL} 



# local tests without fork
test  :; forge test -vv --fork-url ${FORK_URL}
test-op :; forge test -vv --fork-url ${OPTIMISM_RPC_URL}
test-arb :; forge test -vv --fork-url ${ARBI_RPC_URL}
test-mainnet :; forge test -vv --fork-url ${ETH_RPC_URL}	

trace  :; forge test -vvv --fork-url ${FORK_URL}
gas  :; forge test --fork-url ${FORK_URL} --gas-report
test-contract  :; forge test -vv --match-contract $(contract) --fork-url ${FORK_URL}
test-contract-gas  :; forge test --gas-report --match-contract ${contract} --fork-url ${FORK_URL}
trace-contract  :; forge test -vvv --match-contract $(contract) --fork-url ${FORK_URL}
test-test  :; forge test -vv --match-test $(test) --fork-url ${FORK_URL}
trace-test  :; forge test -vvv --match-test $(test) --fork-url ${FORK_URL}
snapshot :; forge snapshot -vv --fork-url ${FORK_URL}
snapshot-diff :; forge snapshot --diff -vv --fork-url ${FORK_URL}

test-all :; 
	forge test -vv --fork-url ${ETH_RPC_URL}
	forge test -vv --fork-url ${OPTIMISM_RPC_URL}
	forge test -vv --fork-url ${ARBI_RPC_URL}


clean  :; forge clean
