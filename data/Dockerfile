FROM makarius/isabelle:Isabelle2025-2_X11_Latex

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends make socat xauth xvfb \
    && rm -rf /var/lib/apt/lists/*

COPY --chown=isabelle:isabelle d/AutoCorrode/iq /home/isabelle/AutoCorrode/iq
COPY --chown=isabelle:isabelle d/AutoCorrode/isabelle-assistant /home/isabelle/AutoCorrode/isabelle-assistant
COPY --chown=isabelle:isabelle docker-entrypoint.sh /usr/local/bin/isabelle-mcp-entrypoint
COPY --chown=isabelle:isabelle iq-http-bridge.py /usr/local/bin/iq-http-bridge
RUN chmod +x /usr/local/bin/isabelle-mcp-entrypoint /usr/local/bin/iq-http-bridge

USER isabelle
ENV ISABELLE_HOME=/home/isabelle/Isabelle
RUN cd /home/isabelle/AutoCorrode/iq \
    && make ISABELLE_HOME=/home/isabelle/Isabelle INSTALL_DIR=/home/isabelle/.isabelle/jedit/jars install

EXPOSE 8765 8766
ENTRYPOINT ["/usr/local/bin/isabelle-mcp-entrypoint"]
CMD ["jedit"]
