#!/bin/bash
#set -x


#*
#*  Copyright 2019-2020 Saul Alonso Monsalve, Felix Garcia Carballeira, Jose Rivadeneira Lopez-Bravo, Alejandro Calderon Mateos,
#*
#*  This file is part of DaLoFlow.
#*
#*  DaLoFlow is free software: you can redistribute it and/or modify
#*  it under the terms of the GNU Lesser General Public License as published by
#*  the Free Software Foundation, either version 3 of the License, or
#*  (at your option) any later version.
#*
#*  WepSIM is distributed in the hope that it will be useful,
#*  but WITHOUT ANY WARRANTY; without even the implied warranty of
#*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#*  GNU Lesser General Public License for more details.
#*
#*  You should have received a copy of the GNU Lesser General Public License
#*  along with WepSIM.  If not, see <http://www.gnu.org/licenses/>.
#*


daloflow_welcome ()
{
	echo ""
	echo "  daloflow 3.5"
	echo " --------------"
	echo ""
}

daloflow_help ()
{
	echo ": For first time deployment, please execute:"
	echo "  $0 postclone"
	echo "  $0 prerequisites"
	echo "  $0 build"
	echo ""
	echo ": For a typical single node work session (with 4 containers and 2 process), please execute:"
	echo "  $0 start 4"
	echo "  $0 mpirun 2 \"python3 ./horovod/examples/tensorflow2_keras_mnist_saul.py --height 32 --width 32 --path dataset32x32\""
	echo "  ..."
	echo "  $0 stop"
	echo ""
	echo ": For a typical multinode work session (with 4 containers and 2 process), please execute:"
	echo "  $0 swarm-start 4"
	echo "  $0 mpirun 2 \"python3 ./horovod/examples/tensorflow2_keras_mnist_saul.py --height 32 --width 32 --path dataset32x32\""
	echo "  ..."
	echo "  $0 swarm-stop"
	echo ""
	echo ": Available options for (single node) debugging:"
	echo "  $0 bash <id container, from 1 up to nc>"
	echo "  $0 docker_in_docker"
	echo "  $0 save | load | status | test"
	echo ""
	echo ": Please read the README.md file for more information (github.com/saulam/daloflow/)."
	echo ""
}

daloflow_info_no_start ()
{
	echo ": Please start/swarm-start first:"
	echo ""
        echo ": * For a typical single node work session (with 4 containers and 2 process), please execute:"
        echo "    ./daloflow.sh start       <number of containers>"
	echo ""
        echo ": * For a typical multinode work session (with 4 containers and 2 process), please execute:"
        echo "    ./daloflow.sh swarm-start <number of containers>"
	echo ""
}


#
# Installation
#

daloflow_postclone ()
{
	echo "Downloading Source Code for OpenMPI 4.0.5, tensorflow 2.3.0, and Horovod 0.20.3..."

	# MPI
        wget https://www.open-mpi.org/software/ompi/v4.0/downloads/openmpi-4.0.5.tar.gz
	rm -fr openmpi
        tar zxf openmpi-4.0.5.tar.gz
	mv openmpi-4.0.5 openmpi

	# TENSORFLOW
	wget https://github.com/tensorflow/tensorflow/archive/v2.3.0.tar.gz
	rm -fr tensorflow
	tar zxf v2.3.0.tar.gz
	mv tensorflow-2.3.0 tensorflow

	# HOROVOD
	wget https://github.com/horovod/horovod/archive/v0.20.3.tar.gz
	rm -fr horovod
	tar zxf v0.20.3.tar.gz
	mv horovod-0.20.3 horovod
}

daloflow_prerequisites ()
{
	echo "Installing Docker, Docker-compose and Nvidia-container-runtime..."

	# To Install DOCKER
	sudo apt-get update
	sudo apt-get upgrade
	sudo apt-get install -y curl apt-transport-https ca-certificates software-properties-common
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
        curl https://bazel.build/bazel-release.pub.gpg | sudo apt-key add -
	sudo apt-get update
	sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
	sudo apt-get update
	sudo apt install -y docker-ce docker-ce-cli containerd.io

	# To Install DOCKER-COMPOSER
	pip3 install docker-compose

	# NVIDIA GPU: https://nvidia.github.io/nvidia-container-runtime/
	curl -s -L https://nvidia.github.io/nvidia-container-runtime/gpgkey | sudo apt-key add -
	distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
	curl -s -L https://nvidia.github.io/nvidia-container-runtime/$distribution/nvidia-container-runtime.list | \
		  sudo tee /etc/apt/sources.list.d/nvidia-container-runtime.list
	sudo apt-get update
	apt-get install -y nvidia-container-runtime
        #docker run -it --rm --gpus all ubuntu nvidia-smi
}


#
# Image
#

daloflow_build_base_image ()
{
	echo "Building initial image..."
	docker image build -t daloflow:v2 .
}

daloflow_build_derivated_image ()
{
	echo "Building compilation image..."
	daloflow_start 1
        daloflow_build_all

	echo "Commiting image..."
	CONTAINER_ID_LIST=$(docker ps|grep daloflow_node|cut -f1 -d' ')
	docker commit $CONTAINER_ID_LIST daloflow:latest
	docker-compose -f Dockercompose.yml down
}

daloflow_build_all ()
{
	# Install each node
	CONTAINER_ID_LIST=$(docker ps|grep daloflow_node|cut -f1 -d' ')
	for C in $CONTAINER_ID_LIST; do
		docker container exec -it $C ./daloflow.sh build_node 
	done
}

daloflow_build_node ()
{
	echo "Build source code..."

	# OpenMPI
	# from source:
        cd /usr/src/daloflow/openmpi
	./configure --enable-orterun-prefix-by-default
	make -j $(nproc) all
	make install
	ldconfig

	# TENSORFLOW
	# from source:
        cd /usr/src/daloflow/tensorflow
        yes "" | $(which python3) configure.py
        bazel build --config=opt //tensorflow/tools/pip_package:build_pip_package --action_env PYTHON_BIN_PATH=/usr/bin/python3 
        ./bazel-bin/tensorflow/tools/pip_package/build_pip_package /usr/src/daloflow/tensorflow/tensorflow_pkg
        pip3 install /usr/src/daloflow/tensorflow/tensorflow_pkg/tensorflow-*.whl

	# HOROVOD
	# from package # HOROVOD_WITH_MPI=1 HOROVOD_WITH_TENSORFLOW=1 pip3 install --no-cache-dir horovod
	# from source:
        cd /usr/src/daloflow/horovod
        python3 setup.py clean
        CFLAGS="-march=native -mavx -mavx2 -mfma -mfpmath=sse" python3 setup.py bdist_wheel
        HOROVOD_WITH_MPI=1 HOROVOD_WITH_TENSORFLOW=1 pip3 install ./dist/horovod-*.whl
}

daloflow_save ()
{
	echo "Saving daloflow:v2 image..."
	IMAGE_ID_LIST=$(docker image ls|grep daloflow|grep latest|awk '{print $3}')
	docker image save daloflow:v2 | gzip -5 > daloflow_v2.tgz 
}

daloflow_load ()
{
	echo "Loading daloflow:v2 image..."
	cat daloflow_v2.tgz | gunzip - | docker image load
}


#
# Execution
#

daloflow_start ()
{
	# Setup number of containers
	NC=$1
	if [ $# -lt 1 ]; then
	     NC=1
	fi

	# Start container cluster (in single node)
	docker-compose -f Dockercompose.yml up -d --scale node=$NC
	echo "wating $NC seconds..."
	sleep $NC

	# Container cluster (in single node) files...
	CONTAINER_ID_LIST=$(docker ps -f name=daloflow -q)
	docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $CONTAINER_ID_LIST > machines_mpi
	docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $CONTAINER_ID_LIST | sed 's/.*/& slots=1 max_slots=16/g' > machines_horovod

	if [ $(getent group daloflow) ]; then
	     chgrp daloflow machines_*
	fi

}

daloflow_stop ()
{
	# stop composition
	docker-compose -f Dockercompose.yml down

        # Remove container cluster files...
	rm -fr machines_mpi
	rm -fr machines_horovod
}

daloflow_swarm_start ()
{
        # Setup number of containers
        NC=$1
        if [ $# -lt 1 ]; then
             NC=1
        fi

        # Start container cluster
        docker stack deploy --compose-file Dockerstack.yml daloflow
        docker service scale daloflow_node=$NC

        # Container cluster files...
        CONTAINER_ID_LIST=$(docker service ps daloflow_node -f desired-state=running -q)
        docker inspect -f '{{range .NetworksAttachments}}{{.Addresses}}{{end}}' $CONTAINER_ID_LIST | sed "s/^\[//g" | awk 'BEGIN {FS="/"} ; {print $1}' > machines_mpi
        cat machines_mpi | sed 's/.*/& slots=1/g' > machines_horovod
}

daloflow_swarm_stop ()
{
	# Stop service
	docker service rm daloflow_node

        # Remove container cluster files...
	rm -fr machines_mpi
	rm -fr machines_horovod
}

daloflow_run ()
{
	# Get parameters
	NP=$1
	shift
	A=$@
	CNAME=$(docker ps -f name=daloflow -q | head -1)

	# Check parameters
	if [ "x$CNAME" == "x" ]; then
            daloflow_welcome
            daloflow_info_no_start
            exit
	fi

        # daloflow:v2 in TUCAN
	docker container exec -it $CNAME     \
	       mpirun -np $NP -machinefile machines_horovod \
		      -bind-to none -map-by slot -verbose --allow-run-as-root \
		       -x NCCL_DEBUG=INFO -x LD_LIBRARY_PATH -x PATH \
		       -x NCCL_SOCKET_IFNAME=^lo,docker0 \
		       -mca pml ob1 -mca btl ^openib \
		       -mca btl_tcp_if_exclude lo,docker0,eth1 \
		      $A
}

daloflow_bash_node ()
{
	# Check parameters
	if [ ! -f machines_mpi ]; then
            daloflow_welcome
            daloflow_info_no_start
            exit
	fi

	CIP=$(head -$1 machines_mpi | tail -1)
	CNAME=$(docker ps -f name=daloflow -q | head -1)
	docker container exec -it $CNAME /usr/bin/ssh $CIP
}


#
# Testing
#

daloflow_test ()
{
	# Install each node
	CONTAINER_ID_LIST=$(docker ps -f name=daloflow -q)
	for C in $CONTAINER_ID_LIST; do
		docker container exec -it $C ./daloflow.sh test_node 
	done
}

daloflow_test_node ()
{
	# MPICH
	# execute cpi
	cd /usr/src/daloflow/mpich/examples
	mpicc -o cpi cpi.c
	mpirun -np 2 -machinefile /usr/src/daloflow/machines_mpi $(pwd)/cpi

	# HOROVOD
	mpirun -np 2 -machinefile machines_mpi -bind-to none -map-by slot python3 ./horovod/examples/tensorflow2_mnist.py
	# horovodrun --verbose -np 2 -hostfile machines_horovod  python3 ./horovod/examples/tensorflow2_mnist.py
}


#
# Main
#

# Usage
if [ $# -eq 0 ]; then
        daloflow_welcome
	daloflow_help $0
	exit
fi

# for each argument, try to execute it
while (( "$#" )); 
do
	case $1 in
	     # first execution
	     prerequisites)
		daloflow_prerequisites
	     ;;
	     postclone)
		daloflow_postclone
	     ;;

	     # image
	     build|image)
                daloflow_build_base_image
	     ;;
	     save)
                daloflow_save
	     ;;
	     load)
                daloflow_load
	     ;;
	     build_image)
                daloflow_build_base_image
		daloflow_build_derivated_image
	     ;;
	     build_all)
		daloflow_build_all
	     ;;
	     build_node)
		daloflow_build_node
	     ;;

	     # single node
	     start)
		shift
		daloflow_start $@
	     ;;
	     stop)
                daloflow_stop
	     ;;

	     # multinode node
	     swarm-start)
		shift
		daloflow_swarm_start $@
	     ;;
	     swarm-stop)
                daloflow_swarm_stop
	     ;;

	     # mpirun + bash
	     mpirun|swarm-mpirun)
		shift
                daloflow_run $@
	     ;;
	     bash)
		shift
                daloflow_bash_node $@
	     ;;

	     # single node utilities
	     status|ps)
		docker ps
	     ;;
	     test)
		daloflow_test
	     ;;
	     test_node)
		daloflow_test_node
	     ;;
             docker_in_docker)
		docker run --network host -v $(pwd):/usr/src/daloflow -v "/var/run/docker.sock:/var/run/docker.sock" --runtime=nvidia -it ubuntu /bin/bash
	     ;;

	     # help
	     *)
                daloflow_welcome
		daloflow_help $0
	     ;;
	esac
	shift
done


