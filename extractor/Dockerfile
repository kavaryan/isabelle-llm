FROM makarius/isabelle:Isabelle2025-2

COPY --chown=isabelle:isabelle extractor /home/isabelle/extractor

USER root
RUN mkdir -p /out \
    && chown isabelle:isabelle /out

USER isabelle
ENV ISABELLE_HOME=/home/isabelle/Isabelle
ENV PATH="${ISABELLE_HOME}/bin:${PATH}"
WORKDIR /home/isabelle/extractor

RUN isabelle components -u /home/isabelle/extractor \
    && isabelle scala_build \
    && isabelle proof_extractor -? 2>&1 | grep -q "Usage: isabelle proof_extractor"

VOLUME ["/out"]
USER root
ENV HOME=/home/isabelle
ENTRYPOINT ["isabelle", "proof_extractor", "-d", "/out"]
