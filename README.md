# tf-gcp-shenanigans

* **Project State: Prototyping**
* For more information on project states and SLAs, see [this documentation](https://github.com/chef/chef-oss-practices/blob/d4333c01570eae69f65470d58ed9d251c2e552a3/repo-management/repo-states.md).

A sandbox for exploring Terraform and Google Cloud API shenanigans. Don't you sometimes wish Terraform could manage implicit dependencies better? 🥲

## Useful commands

To run a Terraform `plan` or `apply` operation:

```shell
terraform plan -input=false -var 'project=ofrolovs-sandbox' -out tfplan
```

```shell
terraform plan -input=false -var 'project=ofrolovs-sandbox' -destroy -out tfplan
```

```shell
terraform apply tfplan
```

To generate a visual representation of either a configuration or execution plan:

```shell
terraform graph > shenanigans-X.dot
```

```shell
terraform graph -plan=tfplan > shenanigans-X.dot
```

# Generate charts

I render Graphviz (`.dot`) files in Visual Studio Code with [tintinweb/vscode-interactive-graphviz](https://github.com/tintinweb/vscode-interactive-graphviz). 
