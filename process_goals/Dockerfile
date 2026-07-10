FROM makarius/isabelle:Isabelle2025-2

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends git curl python3-pip \
    && rm -rf /var/lib/apt/lists/*
ARG OPENCODE_VERSION=1.17.11
RUN curl -fsSL https://opencode.ai/install | bash -s -- --version "$OPENCODE_VERSION" \
    && mv /root/.opencode/bin/opencode /usr/local/bin/opencode

USER isabelle
ENV ISABELLE_HOME=/home/isabelle/Isabelle
RUN git clone --depth=1 https://github.com/awslabs/AutoCorrode /home/isabelle/AutoCorrode
RUN python3 -m pip install --break-system-packages -r /home/isabelle/AutoCorrode/ir/requirements.txt

COPY --chown=isabelle:isabelle . /home/isabelle/process_goals
RUN mkdir -p /home/isabelle/.isabelle/etc \
    && echo /home/isabelle/process_goals >> /home/isabelle/.isabelle/etc/components \
    && Isabelle/bin/isabelle goals_run -P list

ENV IR_DIR=/home/isabelle/AutoCorrode/ir
WORKDIR /home/isabelle/process_goals
ENTRYPOINT ["/home/isabelle/Isabelle/bin/isabelle"]
