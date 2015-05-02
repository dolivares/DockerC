export OCI_INCLUDE_DIR=/opt/instantclient/sdk/include/
export OCI_LIB_DIR=/opt/instantclient/

if [ -z "$LD_LIBRARY_PATH" ]; then
	export LD_LIBRARY_PATH=/opt/instantclient/
else
	LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/instantclient/
fi

# 
# Configure user's env to enable connectivity to development 
# oracle server on vm's private network.
export DATABASE_URL=oracle://jade:jade@10.10.10.200:1521/xe

#
# Configure REDIS URL variable
export REDIS_URL="redis://$REDIS_PORT_6379_TCP_ADDR:$REDIS_PORT_6379_TCP_PORT"

#
# Set default value for PORT env var
export PORT=3000

#
# This alias assumes your clone of reg5 is named "reg5".
alias cleannm="cd /var/lib/nodeapps/reg5/mateo; rm -rf node_modules; cd ../site; rm -rf node_modules"
alias installnm="cd /var/lib/nodeapps/reg5/mateo; npm install; npm-install-missing; cd ../site; npm install; npm-install-missing"
alias startn="cd /var/lib/nodeapps/reg5; node nodemon app.js"
alias startnd="cd /var/lib/nodeapps/reg5; node nodemon —debug app.js"
alias upd="cleannm; installnm; startnd"
alias up="cleannm; installnm; startn"

#
# Init nvm env
source /home/docker/.nvm/nvm.sh

#
# some more aliases
alias n8="nvm use 0.8.12"
alias n10="nvm use 0.10.25"

