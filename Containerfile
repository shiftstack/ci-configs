FROM registry.ci.openshift.org/origin/4.8:base

ARG dev_install_url=https://github.com/shiftstack/dev-install/archive/refs/tags/v0.1.tar.gz
ARG dev_install_sha256=dcf9f28bd52d6ccfdb0f588c4d16a9952ecb5230757b58306db100e6fd450c82

ARG default_user=1000:1000

RUN dnf update -y && \
    dnf install --setopt=tsflags=nodocs -y \
    ansible make && \
    dnf clean all && rm -rf /var/cache/dnf/*

RUN mkdir -p /src/dev-install \
	&& curl -sSL $dev_install_url \
	| tee dev-install.tar.gz \
	| sha256sum -c <(printf "%s  -" "$dev_install_sha256") \
	&& tar xzvf dev-install.tar.gz --strip=1 -C /src/dev-install/ \
	&& rm dev-install.tar.gz

RUN chown --recursive $default_user /src
USER $default_user
ENV IS_CI=1
ENV WORK_DIR=/src
COPY ./ /src
ENV HOME /src
WORKDIR /src
