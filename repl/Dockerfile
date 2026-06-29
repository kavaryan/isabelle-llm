FROM makarius/isabelle:Isabelle2025-2_X11_Latex

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends make python3-pip socat xauth xvfb \
    && rm -rf /var/lib/apt/lists/*
RUN ln -sfn /home/isabelle/Isabelle /home/isabelle/Isabelle2025-2
RUN chown root:root /home/isabelle/Isabelle/contrib/vscodium-*/x86_64-linux/chrome-sandbox \
    && chmod 4755 /home/isabelle/Isabelle/contrib/vscodium-*/x86_64-linux/chrome-sandbox

COPY --chown=isabelle:isabelle tmp/AutoCorrode/ir/requirements.txt /tmp/AutoCorrode/ir/requirements.txt
RUN python3 -m pip install --break-system-packages -r /tmp/AutoCorrode/ir/requirements.txt
COPY --chown=isabelle:isabelle tmp/AutoCorrode/iq /home/isabelle/AutoCorrode/iq
COPY --chown=isabelle:isabelle tmp/AutoCorrode/ir /home/isabelle/AutoCorrode/ir
COPY --chown=isabelle:isabelle tmp/AutoCorrode/isabelle-assistant /home/isabelle/AutoCorrode/isabelle-assistant
COPY --chown=isabelle:isabelle docker-entrypoint.sh /usr/local/bin/isabelle-mcp-entrypoint
COPY --chown=isabelle:isabelle iq-http-bridge.py /usr/local/bin/iq-http-bridge
RUN chmod +x /usr/local/bin/isabelle-mcp-entrypoint /usr/local/bin/iq-http-bridge

USER isabelle
ENV ISABELLE_HOME=/home/isabelle/Isabelle
ENV ELECTRON_DISABLE_SANDBOX=1
RUN cd /home/isabelle/AutoCorrode/iq \
    && make ISABELLE_HOME=/home/isabelle/Isabelle INSTALL_DIR=/home/isabelle/.isabelle/jedit/jars install

EXPOSE 18765 8766
ENTRYPOINT ["/usr/local/bin/isabelle-mcp-entrypoint"]
CMD ["jedit"]
