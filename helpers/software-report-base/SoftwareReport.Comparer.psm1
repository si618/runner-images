using module ./SoftwareReport.psm1
using module ./SoftwareReport.BaseNodes.psm1
using module ./SoftwareReport.Nodes.psm1
using module ./SoftwareReport.ComparerReport.psm1

# SoftwareReportComparer is used to calculate differences between two SoftwareReport objects
class SoftwareReportComparer {
    [ValidateNotNullOrEmpty()]
    hidden [SoftwareReport] $PreviousReport
    [ValidateNotNullOrEmpty()]
    hidden [SoftwareReport] $CurrentReport

    hidden [Collections.Generic.List[ReportDifferenceItem]] $AddedItems
    hidden [Collections.Generic.List[ReportDifferenceItem]] $ChangedItems
    hidden [Collections.Generic.List[ReportDifferenceItem]] $DeletedItems

    SoftwareReportComparer([SoftwareReport] $PreviousReport, [SoftwareReport] $CurrentReport) {
        $this.PreviousReport = $PreviousReport
        $this.CurrentReport = $CurrentReport
    }

    [void] CompareReports() {
        $this.AddedItems = @()
        $this.ChangedItems = @()
        $this.DeletedItems = @()

        $this.CompareInternal($this.PreviousReport.Root, $this.CurrentReport.Root, @())
    }

    hidden [void] CompareInternal([HeaderNode] $previousReportPointer, [HeaderNode] $currentReportPointer, [Array] $Headers) {
        $currentReportPointer.Children ?? @() | Where-Object { $_.ShouldBeIncludedToDiff() -and $this.FilterExcludedNodes($_) } | ForEach-Object {
            $currentReportNode = $_
            $sameNodeInPreviousReport = $previousReportPointer ? $previousReportPointer.FindSimilarChildNode($currentReportNode) : $null

            if ($currentReportNode -is [HeaderNode]) {
                $this.CompareInternal($sameNodeInPreviousReport, $currentReportNode, $Headers + $currentReportNode.Title)
            } else {
                if ($sameNodeInPreviousReport -and ($currentReportNode.IsIdenticalTo($sameNodeInPreviousReport))) {
                    # Nodes are identical, nothing changed, just ignore it
                } elseif ($sameNodeInPreviousReport) {
                    # Nodes are equal but not identical, so something was changed
                    if ($currentReportNode -is [TableNode]) {
                        $this.CompareSimilarTableNodes($sameNodeInPreviousReport, $currentReportNode, $Headers)
                    } elseif ($currentReportNode -is [ToolVersionsListNode]) {
                        $this.CompareSimilarToolVersionsListNodes($sameNodeInPreviousReport, $currentReportNode, $Headers)
                    } else {
                        $this.ChangedItems.Add([ReportDifferenceItem]::new($sameNodeInPreviousReport, $currentReportNode, $Headers))
                    }
                } else {
                    # Node was not found in previous report, new node was added
                    $this.AddedItems.Add([ReportDifferenceItem]::new($null, $currentReportNode, $Headers))
                }
            }
        }

        # Detecting nodes that were removed
        $previousReportPointer.Children ?? @() | Where-Object { $_.ShouldBeIncludedToDiff() -and $this.FilterExcludedNodes($_) } | ForEach-Object {
            $previousReportNode = $_
            $sameNodeInCurrentReport = $currentReportPointer ? $currentReportPointer.FindSimilarChildNode($previousReportNode) : $null

            if (-not $sameNodeInCurrentReport) {
                if ($previousReportNode -is [HeaderNode]) {
                    $this.CompareInternal($previousReportNode, $null, $Headers + $previousReportNode.Title)
                } else {
                    $this.DeletedItems.Add([ReportDifferenceItem]::new($previousReportNode, $null, $Headers))
                }
            }
        }
    }

    hidden [void] CompareSimilarTableNodes([TableNode] $PreviousReportNode, [TableNode] $CurrentReportNode, [Array] $Headers) {
        $addedRows = $CurrentReportNode.Rows | Where-Object { $_ -notin $PreviousReportNode.Rows }
        $deletedRows = $PreviousReportNode.Rows | Where-Object { $_ -notin $CurrentReportNode.Rows }

        if (($addedRows.Count -gt 0) -and ($deletedRows.Count -eq 0)) {
            $this.AddedItems.Add([ReportDifferenceItem]::new($PreviousReportNode, $CurrentReportNode, $Headers))
        } elseif (($deletedRows.Count -gt 0) -and ($addedRows.Count -eq 0)) {
            $this.DeletedItems.Add([ReportDifferenceItem]::new($PreviousReportNode, $CurrentReportNode, $Headers))
        } else {
            $this.ChangedItems.Add([ReportDifferenceItem]::new($PreviousReportNode, $CurrentReportNode, $Headers))
        }
    }

    hidden [void] CompareSimilarToolVersionsListNodes([ToolVersionsListNode] $PreviousReportNode, [ToolVersionsListNode] $CurrentReportNode, [Array] $Headers) {
        $previousReportMajorVersions = $PreviousReportNode.Versions | ForEach-Object { $PreviousReportNode.ExtractMajorVersion($_) }
        $currentReportMajorVersion = $CurrentReportNode.Versions | ForEach-Object { $CurrentReportNode.ExtractMajorVersion($_) }

        $addedVersions = $CurrentReportNode.Versions | Where-Object { $CurrentReportNode.ExtractMajorVersion($_) -notin $previousReportMajorVersions }
        $deletedVersions = $PreviousReportNode.Versions | Where-Object { $PreviousReportNode.ExtractMajorVersion($_) -notin $currentReportMajorVersion }
        $changedPreviousVersions = $PreviousReportNode.Versions | Where-Object { ($PreviousReportNode.ExtractMajorVersion($_) -in $currentReportMajorVersion) -and ($_ -notin $CurrentReportNode.Versions) }
        $changedCurrentVersions = $CurrentReportNode.Versions | Where-Object { ($CurrentReportNode.ExtractMajorVersion($_) -in $previousReportMajorVersions) -and ($_ -notin $PreviousReportNode.Versions) }

        if ($addedVersions.Count -gt 0) {
            $this.AddedItems.Add([ReportDifferenceItem]::new($null, [ToolVersionsListNode]::new($CurrentReportNode.ToolName, $addedVersions, $CurrentReportNode.MajorVersionRegex, "List"), $Headers))
        }

        if ($deletedVersions.Count -gt 0) {
            $this.DeletedItems.Add([ReportDifferenceItem]::new([ToolVersionsListNode]::new($PreviousReportNode.ToolName, $deletedVersions, $PreviousReportNode.MajorVersionRegex, "List"), $null, $Headers))
        }

        $previousChangedNode = ($changedPreviousVersions.Count -gt 0) ? [ToolVersionsListNode]::new($PreviousReportNode.ToolName, $changedPreviousVersions, $PreviousReportNode.MajorVersionRegex, "List") : $null
        $currentChangedNode = ($changedCurrentVersions.Count -gt 0) ? [ToolVersionsListNode]::new($CurrentReportNode.ToolName, $changedCurrentVersions, $CurrentReportNode.MajorVersionRegex, "List") : $null
        if ($previousChangedNode -and $currentChangedNode) {
            $this.ChangedItems.Add([ReportDifferenceItem]::new($previousChangedNode, $currentChangedNode, $Headers))
        }
    }

    [String] GetMarkdownReport() {
        $reporter = [SoftwareReportComparerReport]::new()
        $report = $reporter.GenerateMarkdownReport($this.CurrentReport, $this.PreviousReport, $this.AddedItems, $this.ChangedItems, $this.DeletedItems)
        return $report
    }

    hidden [Boolean] FilterExcludedNodes([BaseNode] $Node) {
        # We shouldn't show "Image Version" diff because it is already shown in report header
        if (($Node -is [ToolVersionNode]) -and ($Node.ToolName -eq "Image Version:")) {
            return $false
        }

        return $true
    }
}