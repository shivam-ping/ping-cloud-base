Password generator for the opensearch security-config:

`pip install bcrypt`

```python
python -c 'import bcrypt; print(bcrypt.hashpw("admin".encode("utf-8"), bcrypt.gensalt(12, prefix=b"2a")).decode("utf-8"))'
```
Username and password used for the OS Dashboard communication with OS should be base64 encoded w/o newline

```shell
❯ echo -n admin | base64
YWRtaW4=
```

CRDs and controller-manager can be installed using helm

```shell
git clone git@github.com:Opster/opensearch-k8s-operator.git
cd opensearch-k8s-operator/charts/opensearch-operator
helm template -n elastic-stack-logging os . --set fullnameOverride=os --create-namespace --set installCRDS=true --output-dir ./generated
```

Generated manifests will be located at `generated/opensearch-operator/templates` and can be moved to the kustomization.


Sources:
https://github.com/opensearch-project/opensearch-k8s-operator/blob/main/docs/userguide/main.md