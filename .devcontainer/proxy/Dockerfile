FROM python:3.12-slim

RUN pip install --no-cache-dir mitmproxy==11.1.3 PyYAML

RUN useradd --system --create-home mitmproxy

COPY enforcer.py /opt/proxy/enforcer.py
COPY policy.yaml /opt/proxy/policy.yaml

RUN mkdir -p /home/mitmproxy/.mitmproxy && \
    chown -R mitmproxy:mitmproxy /home/mitmproxy

USER mitmproxy
EXPOSE 8080

CMD ["mitmdump", "--mode", "regular", "--listen-port", "8080", \
     "--set", "connection_strategy=lazy", \
     "-s", "/opt/proxy/enforcer.py"]
