#!/bin/bash
set -ex

source ${UTILS_DIR}/utilities.sh

# Load gcc
set CC=/usr/bin/gcc
set GCC=/usr/bin/gcc

INSTALL_PREFIX=/opt

apt-get install -y rdma-core libibverbs-dev librdmacm-dev
# apt-get -y install openmpi-bin \
#             libopenmpi-dev \
#             openmpi-common \
#             openmpi-doc \
#             libopenmpi3

# apt-get -y install libfabric-dev \
#                    libfabric1 \
#                    libfabric-bin

apt-get -y install ibverbs-utils

# # Setup module files for MPIs
# MPI_MODULE_FILES_DIRECTORY=${MODULE_FILES_DIRECTORY}/mpi
# mkdir -p ${MPI_MODULE_FILES_DIRECTORY}

# # OpenMPI
# OMPI_VERSION=4.1.6
# cat << EOF >> /usr/share/modules/modulefiles/mpi/openmpi-${OMPI_VERSION}
# #%Module 1.0
# #
# #  OpenMPI ${OMPI_VERSION}
# #
# conflict        mpi
# prepend-path    PATH            /usr/bin
# prepend-path    LD_LIBRARY_PATH /usr/lib/aarch64-linux-gnu/openmpi/lib
# prepend-path    MANPATH         /usr/share/man
# setenv          MPI_BIN         /usr/bin
# setenv          MPI_INCLUDE     /usr/lib/aarch64-linux-gnu/openmpi/include
# setenv          MPI_LIB         /usr/lib/aarch64-linux-gnu/openmpi/lib
# setenv          MPI_MAN         /usr/share/man
# setenv          MPI_HOME        /usr/lib/aarch64-linux-gnu/openmpi
# EOF

# ln -s ${MPI_MODULE_FILES_DIRECTORY}/openmpi-${OMPI_VERSION} ${MPI_MODULE_FILES_DIRECTORY}/openmpi
# write_component_version "OMPI" ${OMPI_VERSION}