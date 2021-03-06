ARG ARCH="amd64"
ARG TAG="v3.13.3"
ARG UBI_IMAGE=registry.access.redhat.com/ubi7/ubi-minimal:latest
ARG GO_IMAGE=rancher/hardened-build-base:v1.15.2b5
FROM ${UBI_IMAGE} as ubi
FROM ${GO_IMAGE} as builder
# setup required packages
RUN set -x \
 && apk --no-cache add \
    bash \
    curl \
    file \
    gcc \
    git \
    linux-headers \
    make

### BEGIN K3S XTABLES ###
FROM builder AS k3s_xtables
ARG ARCH
ARG K3S_ROOT_VERSION=v0.6.0-rc3
ADD https://github.com/rancher/k3s-root/releases/download/${K3S_ROOT_VERSION}/k3s-root-xtables-${ARCH}.tar /opt/xtables/k3s-root-xtables.tar
RUN tar xvf /opt/xtables/k3s-root-xtables.tar -C /opt/xtables
### END K3S XTABLES #####

FROM calico/bpftool:v5.3-${ARCH} AS calico_bpftool
FROM calico/bird:v0.3.3-160-g7df7218c-${ARCH} AS calico_bird

### BEGIN CALICOCTL ###
FROM builder AS calico_ctl
ARG TAG
RUN git clone --depth=1 https://github.com/projectcalico/calicoctl.git $GOPATH/src/github.com/projectcalico/calicoctl
WORKDIR $GOPATH/src/github.com/projectcalico/calicoctl
RUN git fetch --all --tags --prune
RUN git checkout tags/${TAG} -b ${TAG}
RUN GO_LDFLAGS="-linkmode=external \
    -X github.com/projectcalico/calicoctl/calicoctl/commands.VERSION=${TAG} \
    -X github.com/projectcalico/calicoctl/calicoctl/commands.GIT_REVISION=$(git rev-parse --short HEAD) \
    " go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/calicoctl ./calicoctl/calicoctl.go
RUN go-assert-static.sh bin/*
RUN go-assert-boring.sh bin/*
RUN install -s bin/* /usr/local/bin
RUN calicoctl --version
### END CALICOCTL #####


### BEGIN CALICO CNI ###
FROM builder AS calico_cni
ARG TAG
RUN git clone --depth=1 https://github.com/projectcalico/cni-plugin.git $GOPATH/src/github.com/projectcalico/cni-plugin
WORKDIR $GOPATH/src/github.com/projectcalico/cni-plugin
RUN git fetch --all --tags --prune
RUN git checkout tags/${TAG} -b ${TAG}
ENV GO_LDFLAGS="-linkmode=external -X main.VERSION=${TAG}"
RUN go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/calico ./cmd/calico
RUN go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/calico-ipam ./cmd/calico-ipam
RUN go-assert-static.sh bin/*
RUN go-assert-boring.sh bin/*
RUN mkdir -vp /opt/cni/bin
RUN install -s bin/* /opt/cni/bin/
RUN install -m 0755 k8s-install/scripts/install-cni.sh /opt/cni/install-cni.sh
RUN install -m 0644 k8s-install/scripts/calico.conf.default /opt/cni/calico.conf.default
### END CALICO CNI #####


### BEGIN CALICO NODE ###
FROM builder AS calico_node
ARG TAG
RUN git clone --depth=1 https://github.com/projectcalico/node.git $GOPATH/src/github.com/projectcalico/node
WORKDIR $GOPATH/src/github.com/projectcalico/node
RUN git fetch --all --tags --prune
RUN git checkout tags/${TAG} -b ${TAG}
RUN GO_LDFLAGS="-linkmode=external \
    -X github.com/projectcalico/node/pkg/startup.VERSION=${TAG} \
    -X github.com/projectcalico/node/buildinfo.GitRevision=$(git rev-parse HEAD) \
    -X github.com/projectcalico/node/buildinfo.GitVersion=$(git describe --tags --always) \
    -X github.com/projectcalico/node/buildinfo.BuildDate=$(date -u +%FT%T%z) \
    " go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/calico-node ./cmd/calico-node
RUN go-assert-static.sh bin/*
RUN go-assert-boring.sh bin/*
RUN install -s bin/* /usr/local/bin
### END CALICO NODE #####


### BEGIN CALICO POD2DAEMON ###
FROM builder AS calico_pod2daemon
ARG TAG
RUN git clone --depth=1 https://github.com/projectcalico/pod2daemon.git $GOPATH/src/github.com/projectcalico/pod2daemon
WORKDIR $GOPATH/src/github.com/projectcalico/pod2daemon
RUN git fetch --all --tags --prune
RUN git checkout tags/${TAG} -b ${TAG}
ENV GO_LDFLAGS="-linkmode=external"
RUN go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/flexvoldriver ./flexvol
RUN go-assert-static.sh bin/*
RUN install -m 0755 flexvol/docker/flexvol.sh /usr/local/bin/
RUN install -D -s bin/flexvoldriver /usr/local/bin/flexvol/flexvoldriver
### END CALICO POD2DAEMON #####


### BEGIN CNI PLUGINS ###
FROM builder AS cni_plugins
ARG TAG
ARG CNI_PLUGINS_VERSION="v0.8.7"
RUN git clone --depth=1 https://github.com/containernetworking/plugins.git $GOPATH/src/github.com/containernetworking/plugins
WORKDIR $GOPATH/src/github.com/containernetworking/plugins
RUN git fetch --all --tags --prune
RUN git checkout tags/${CNI_PLUGINS_VERSION} -b ${CNI_PLUGINS_VERSION}
RUN sh -ex ./build_linux.sh -v \
    -gcflags=-trimpath=/go/src \
    -ldflags " \
        -X github.com/containernetworking/plugins/pkg/utils/buildversion.BuildVersion=${CNI_PLUGINS_VERSION} \
        -linkmode=external -extldflags \"-static -Wl,--fatal-warnings\" \
    "
RUN go-assert-static.sh bin/*
RUN go-assert-boring.sh \
    bin/bandwidth \
    bin/bridge \
    bin/dhcp \
    bin/firewall \
    bin/host-device \
    bin/host-local \
    bin/ipvlan \
    bin/macvlan \
    bin/portmap \
    bin/ptp \
    bin/vlan
# install (with strip) to /opt/cni/bin
RUN mkdir -vp /opt/cni/bin
RUN install -D -s bin/* /opt/cni/bin
### END CNI PLUGINS #####


### BEGIN RUNIT ###
# We need to build runit because there aren't any rpms for it in CentOS or ubi repositories.
FROM centos:7 AS runit
ARG RUNIT_VER=2.1.2
# Install build dependencies and security updates.
RUN yum install -y rpm-build yum-utils make && \
    yum install -y wget glibc-static gcc    && \
    yum -y update-minimal --security --sec-severity=Important --sec-severity=Critical
# runit is not available in ubi or CentOS repos so build it.
ADD http://smarden.org/runit/runit-${RUNIT_VER}.tar.gz /tmp/runit.tar.gz
WORKDIR /opt/local
RUN tar xzf /tmp/runit.tar.gz --strip-components=2 -C .
RUN ./package/install
### END RUNIT #####


# gather all of the disparate calico bits into a rootfs overlay
FROM scratch AS calico_rootfs_overlay
COPY --from=calico_node /go/src/github.com/projectcalico/node/filesystem/etc/       /etc/
COPY --from=calico_node /go/src/github.com/projectcalico/node/filesystem/licenses/  /licenses/
COPY --from=calico_node /go/src/github.com/projectcalico/node/filesystem/sbin/      /usr/sbin/
COPY --from=calico_node /usr/local/bin/      	/usr/bin/
COPY --from=calico_ctl /usr/local/bin/calicoctl /calicoctl
COPY --from=calico_bird /bird*                  /usr/bin/
COPY --from=calico_bpftool /bpftool             /usr/sbin/
COPY --from=calico_pod2daemon /usr/local/bin/   /usr/local/bin/
COPY --from=calico_cni /opt/cni/                /opt/cni/
COPY --from=cni_plugins /opt/cni/               /opt/cni/
COPY --from=k3s_xtables /opt/xtables/bin/       /usr/sbin/
COPY --from=runit /opt/local/command/           /usr/sbin/


FROM ubi
RUN microdnf update -y                         && \
    microdnf install hostname                     \
    libpcap libmnl libnetfilter_conntrack         \ 
    libnetfilter_cthelper libnetfilter_cttimeout  \
    libnetfilter_queue ipset kmod iputils iproute \
    procps net-tools conntrack-tools which     && \
    rm -rf /var/cache/yum
COPY --from=calico_rootfs_overlay / /
ENV PATH=$PATH:/opt/cni/bin
RUN set -x \
 && test -e /opt/cni/install-cni.sh \
 && ln -vs /opt/cni/install-cni.sh /install-cni.sh \
 && test -e /opt/cni/calico.conf.default \
 && ln -vs /opt/cni/calico.conf.default /calico.conf.tmp
