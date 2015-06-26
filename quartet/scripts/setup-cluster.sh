#!/bin/bash -e -x

## If you want to reuse this script elsewhere, you probably want to
## copy all variables defined in `defaults.sh` here
source $(git rev-parse --show-toplevel)/quartet/scripts/defaults.sh

head_node="${MACHINE_NAME_PREFIX}-1"

## Initial token to keep Machine happy
temp_swarm_dicovery_token="token://$(${DOCKER_SWARM_CREATE})"
swarm_flags="--swarm --swarm-discovery=${temp_swarm_dicovery_token}"

## Actual token to be used with proxied Docker
swarm_dicovery_token="token://$(${DOCKER_SWARM_CREATE})"

for i in '1' '2' '3'; do
  if [ ${i} = '1' ]; then
    ## The first machine shall be the Swarm master
    $DOCKER_MACHINE_CREATE \
      ${swarm_flags} \
      --swarm-master \
      "${MACHINE_NAME_PREFIX}-${i}"
  else
    ## The rest of machines are Swarm slaves
    $DOCKER_MACHINE_CREATE \
      ${swarm_flags} \
      "${MACHINE_NAME_PREFIX}-${i}"
  fi

  ## This environment variable is respected by Weave,
  ## hence it needs to be exported
  export DOCKER_CLIENT_ARGS="$($DOCKER_MACHINE config ${MACHINE_NAME_PREFIX}-${i})"
  eval $($DOCKER_MACHINE env ${MACHINE_NAME_PREFIX}-${i})

  ## We are going to use IPAM, hence we launch it with
  ## the following arguments
  $WEAVE launch -iprange 10.254.255.0/24 -initpeercount 3
  ## WeaveDNS also needs to be launched
  $WEAVE launch-dns "10.255.1.${i}/24" -debug
  ## And now the proxy
  export WEAVEPROXY_DOCKER_ARGS="-v /var/lib/boot2docker:/var/lib/boot2docker"
  $WEAVE launch-proxy --with-dns --tlsverify \
  --tlscacert=/var/lib/boot2docker/ca.pem \
  --tlscert=/var/lib/boot2docker/server.pem \
  --tlskey=/var/lib/boot2docker/server-key.pem \

  ## Let's connect-up the Weave cluster by telling
  ## each of the node about the head node
  if [ ${i} -gt '1' ]; then
    $WEAVE connect $($DOCKER_MACHINE ip ${head_node})
  fi

  ## Default Weave proxy port is 12375, we shall point
  ## Swarm agents at it next
  weave_proxy_endpoint="$($DOCKER_MACHINE ip ${MACHINE_NAME_PREFIX}-${i}):12375"

  ## Now we need restart Swarm agents like this
  $DOCKER ${DOCKER_CLIENT_ARGS} rm -f swarm-agent
  $DOCKER ${DOCKER_CLIENT_ARGS} run -d --name=swarm-agent \
    swarm join \
    --addr ${weave_proxy_endpoint} ${swarm_dicovery_token}
done

## Next we will also restart the Swarm master with the new token
export DOCKER_CLIENT_ARGS=$($DOCKER_MACHINE config ${head_node})
eval $($DOCKER_MACHINE env ${head_node})

$DOCKER ${DOCKER_CLIENT_ARGS} rm -f swarm-agent-master
$DOCKER ${DOCKER_CLIENT_ARGS} run -d --name=swarm-agent-master \
  -p 3376:3376 \
  -v /var/lib/boot2docker:/var/lib/boot2docker \
  swarm manage \
  --tlsverify \
  --tlscacert=/var/lib/boot2docker/ca.pem \
  --tlscert=/var/lib/boot2docker/server.pem \
  --tlskey=/var/lib/boot2docker/server-key.pem \
  -H "tcp://0.0.0.0:3376" ${swarm_dicovery_token}

## And make sure Weave cluster setup is comple
$WEAVE status
