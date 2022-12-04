# tf-gcp-shenanigans

A sandbox for exploring Terraform and Google Cloud API shenanigans. Don't you sometimes wish Terraform could manage implicit dependencies better? 🥲

```shell
terraform plan -input=false -var 'project=ofrolovs-sandbox' -out tfplan
```

```shell
terraform plan -input=false -var 'project=ofrolovs-sandbox' -destroy -out tfplan
```

```shell
terraform apply tfplan
```

```shell
terraform graph > shenanigans-X.dot
```

```shell
terraform graph -plan=tfplan > shenanigans-X.dot
```

I render Graphviz (`.dot`) files in Visual Studio Code with [tintinweb/vscode-interactive-graphviz](https://github.com/tintinweb/vscode-interactive-graphviz). 
