process ARTIC_ALIGN_TRIM {
    label 'process_single'
    tag "$meta.id"

    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'oras://community.wave.seqera.io/library/longshot:1.0.0--87adca2fab9ee777':
        'community.wave.seqera.io/library/longshot:1.0.0--bd7e35fe51062951' }"

    input:
    tuple val(meta), path(bam)
    path bed

    output:
    tuple val(meta), path('*.trimmed.rg.sorted.bam')      , emit: trimmed_bam
    tuple val(meta), path('*.primertrimmed.rg.sorted.bam'), emit: primer_trimmed_bam
    tuple val(meta), path('*1.txt')                       , emit: report_trimmed
    tuple val(meta), path('*2.txt')                       , emit: report_primer_trimmed

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def args2 = task.ext.args2 ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    align_trim \\
        $bed \\
        $args \\
        --start \\
        --remove-incorrect-pairs \\
        --report ${prefix}.alignreport_1.txt \\
        < $bam 2> ${prefix}.alignreport_1.er \\
        | samtools sort -T ${prefix} - -o ${prefix}.trimmed.rg.sorted.bam

    align_trim \\
        $bed \\
        $args \\
        --remove-incorrect-pairs \\
        --report ${prefix}.alignreport_2.txt \\
        < $bam 2> ${prefix}.alignreport_2.er \\
        | samtools sort -T ${prefix} - -o ${prefix}.primertrimmed.rg.sorted.bam
    """
}
