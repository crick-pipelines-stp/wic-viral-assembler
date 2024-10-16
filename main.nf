#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { params_summary_map   } from './modules/local/util/logging/main'
include { summary_log          } from './modules/local/util/logging/main'
include { multiqc_summary      } from './modules/local/util/logging/main'
include { get_genome_attribute } from './modules/local/util/references/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CONFIG FILES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

ch_multiqc_config = file("$projectDir/assets/multiqc_illumina_config.yml", checkIfExists: true)
ch_multiqc_logo = file("$projectDir/assets/The_Francis_Crick_Institute_logo.png", checkIfExists: true)
ch_seq_sim_config = file(params.seq_sim_config, checkIfExists: true)

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    REFERENCES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def host_fasta = get_genome_attribute(params, 'fasta')
def host_bwa   = get_genome_attribute(params, 'bwa'  )
if(params.host_fasta) {
    host_fasta = params.host_fasta
}
if(params.host_bwa) {
    host_bwa = params.host_bwa
}


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    INIT
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

log.info summary_log(workflow, params, params.debug, params.monochrome_logs)
def summary_params = params_summary_map(workflow, params, params.debug)

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    VALIDATE INPUTS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Check manditory input parameters to see if the files exist if they have been specified
check_param_list = [
    viral_fasta: params.viral_fasta
]
for (param in check_param_list) {
    if (!param.value) {
        exit 1, "Required parameter not specified: ${param.key}"
    }
    else {
        file(param.value, checkIfExists: true)
    }
}

// Check non-manditory input parameters to see if the files exist if they have been specified
check_param_list = [
    params.sample_sheet,
    params.host_fasta,
    params.host_bwa,
    params.seq_sim_ref_dir,
    params.seq_sim_config,
    params.primers_fasta,
    params.primers_csv
]
for (param in check_param_list) { if (param) { file(param, checkIfExists: true) } }

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { SEQ_SIMULATOR                        } from './modules/local/seq_simulator/main'
include { SAMPLESHEET_CHECK                    } from './modules/local/samplesheet/check/main'
include { CAT_FASTQ                            } from './modules/nf-core/cat/fastq/main'
include { GUNZIP as GUNZIP_FASTA               } from './modules/nf-core/gunzip/main'
include { BWA_INDEX                            } from './modules/nf-core/bwa/index/main'
include { BWA_MEM as BWA_ALIGN_HOST            } from './modules/nf-core/bwa/mem/main'
include { SAMTOOLS_VIEW as SAMTOOLS_VIEW_HOST  } from './modules/nf-core/samtools/view/main'
include { SAMTOOLS_SORT as SAMTOOLS_SORT_VIRAL } from './modules/nf-core/samtools/sort/main'
include { SAMTOOLS_FASTQ                       } from './modules/nf-core/samtools/fastq/main'
include { SPADES_ASSEMBLE                      } from './modules/local/spades/assemble/main'
include { CDHIT_CDHIT                          } from './modules/nf-core/cdhit/cdhit/main'
include { SEQTK_FASTA                          } from './modules/local/seqtk/fasta/main'
include { LINUX_COMMAND as MERGE_REFS          } from './modules/local/linux/command/main'
include { BLAST_MAKEBLASTDB                    } from './modules/nf-core/blast/makeblastdb/main'
include { BLAST_BLASTN                         } from './modules/nf-core/blast/blastn/main'
include { BUILD_REFERENCE_FASTA                } from './modules/local/build_reference_fasta/main'
include { ITERATIVE_ALIGNMENT                  } from './modules/local/iterative_alignment/main'
include { IVAR_TRIM                            } from './modules/nf-core/ivar/trim/main'
include { SAMTOOLS_FAIDX                       } from './modules/nf-core/samtools/faidx/main'
include { PICARD_MARKDUPLICATES                } from './modules/nf-core/picard/markduplicates/main'
include { LOFREQ_CALL                          } from './modules/local/lofreq/call/main'
include { MOSDEPTH                             } from './modules/nf-core/mosdepth/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS          } from './modules/local/custom_dumpsoftwareversions.nf'
include { MULTIQC                              } from './modules/nf-core/multiqc/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { FASTQ_TRIM_FASTP_FASTQC                         } from './subworkflows/nf-core/fastq_trim_fastp_fastqc/main'
include { FASTQ_NANOPORE_QC_TRIM                         } from './subworkflows/local/fastq_nanopore_qc_trim/main'
include { BAM_SORT_STATS_SAMTOOLS as BAM_HOST_SORT_STATS  } from './subworkflows/nf-core/bam_sort_stats_samtools/main'
include { BAM_SORT_STATS_SAMTOOLS as BAM_VIRAL_SORT_STATS } from './subworkflows/nf-core/bam_sort_stats_samtools/main'
include { PREPARE_PRIMERS                                 } from './subworkflows/local/prepare_primers/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow {
    ch_versions      = Channel.empty()
    ch_multiqc_files = Channel.empty()
    ch_viral_fasta   = Channel.fromPath(params.viral_fasta).toSortedList().map{[[id:"viral_reference"], it]}
    ch_samplesheet   = Channel.empty()
    ch_host_fasta    = Channel.empty()
    ch_host_bwa      = Channel.empty()
    ch_seq_sim_refs  = Channel.empty()
    ch_trim_primers  = []

    //
    // Init optional input channels
    //
    if(params.sample_sheet) {
        ch_samplesheet = file(params.sample_sheet, checkIfExists: true)
    }
    if(host_fasta) {
        ch_host_fasta = file(host_fasta, checkIfExists: true)
    }
    if(host_bwa) {
        ch_host_bwa = file(host_bwa, checkIfExists: true)
    }
    if (params.generate_reads) {
        ch_seq_sim_refs = Channel.from(file(params.seq_sim_ref_dir, checkIfExists: true))
    }
    if (params.trim_primers && params.primers_fasta) {
        ch_trim_primers = Channel.from(file(params.primers_fasta, checkIfExists: true)).collect()
    }

    //
    // CHANNEL: Branch into single and merge fasta files
    //
    ch_viral_fasta_merge = ch_viral_fasta
    .branch {
        meta, fasta ->
            single  : fasta.size() == 1
                return [ meta, fasta.flatten() ]
            multiple: fasta.size() > 1
                return [ meta, fasta.flatten() ]
    }

    //
    // MODULE: Concat the reference files into one file
    //
    MERGE_REFS (
        ch_viral_fasta_merge.multiple,
        [],
        true
    )
    ch_viral_fasta = MERGE_REFS.out.file.mix(ch_viral_fasta_merge.single)

    ch_viral_fasta | view

    ch_fastq = Channel.empty()
    if(params.generate_reads) {
        //
        // MODULE: Generate fake reads if required
        //
        SEQ_SIMULATOR (
            ch_seq_sim_refs.map{[ [id: "${params.seq_sim_profile}_test"], it ]},
            ch_seq_sim_config,
            params.seq_sim_profile,
            params.seq_sim_num_reads
        )
        ch_fastq = SEQ_SIMULATOR.out.fastq
    }
    else if (params.sample_sheet) {
        //
        // MODULE: Load samplesheet
        //
        SAMPLESHEET_CHECK (
            ch_samplesheet
        )

        //
        // CHANNEL: Construct meta and fastq channel
        //
        ch_fastq = SAMPLESHEET_CHECK.out.csv
        .splitCsv (header:true, sep:",")
        .map {
            it.single_end = true
            def read1 = file(it.read1, checkIfExists: true)
            it.remove("read1")
            it.remove("read2")
            def read2 = null
            if(it.read2) {
                read2 = file(it.read2, checkIfExists: true)
                it.single_end = false
            }

            if (it.read2) {
                [it, [read1, read2]]
            }
            else {
                [it, [read1]]
            }
        }

        //
        // CHANNEL: Branch into single and merge fastqs
        //
        ch_fastq_merge = ch_fastq
        .groupTuple(by: [0])
        .branch {
            meta, fastq ->
                single  : fastq.size() == 1
                    return [ meta, fastq.flatten() ]
                multiple: fastq.size() > 1
                    return [ meta, fastq.flatten() ]
        }

        //
        // MODULE: Concatenate FastQ files from same sample if required
        //
        CAT_FASTQ (
            ch_fastq_merge.multiple
        )
        ch_versions = ch_versions.mix(CAT_FASTQ.out.versions)
        ch_fastq    = CAT_FASTQ.out.reads.mix(ch_fastq_merge.single)
    }

    ch_host_bwa_index = Channel.empty()
    if(params.assemble_ref && host_fasta != null) {
        //
        // MODULE: Uncompress host genome fasta file if required
        //
        if (ch_host_fasta.toString().endsWith(".gz")) {
            ch_host_fasta = GUNZIP_FASTA ( [ [id:ch_host_fasta.baseName], ch_host_fasta ] ).gunzip
            ch_versions = ch_versions.mix(GUNZIP_FASTA.out.versions)
        }
        else {
            ch_host_fasta = Channel.from( [ [ [id:ch_host_fasta.baseName], ch_host_fasta ] ] )
        }

        //
        // MODULES: Uncompress BWA index or generate if required
        //
        if (host_bwa != null) {
            if (ch_host_bwa_index.toString().endsWith(".tar.gz")) {
                UNTAR_BWA ( [[:], ch_host_bwa_index] )
                ch_versions       = ch_versions.mix( UNTAR_BWA.out.versions )
                ch_host_bwa_index = UNTAR_BWA.out.untar

            } else {
                ch_host_bwa_index = Channel.of([[:], host_bwa])
            }
        }
        else {
            BWA_INDEX ( ch_host_fasta )
            ch_versions       = ch_versions.mix(BWA_INDEX.out.versions)
            ch_host_bwa_index = BWA_INDEX.out.index
        }
    }

    if(params.run_illumina_qc_trim) {
        //
        // SUBWORKFLOW: Fastqc and trimming
        //
        FASTQ_TRIM_FASTP_FASTQC (
            ch_fastq,        // ch_reads
            ch_trim_primers, // ch_adapter_fasta
            false,           // val_save_trimmed_fail
            false,           // val_save_merged
            false,           // val_skip_fastp
            false,           // val_skip_fastqc
        )
        ch_versions      = ch_versions.mix(FASTQ_TRIM_FASTP_FASTQC.out.versions)
        ch_multiqc_files = ch_multiqc_files.mix(FASTQ_TRIM_FASTP_FASTQC.out.fastqc_raw_zip.collect{it[1]})
        ch_multiqc_files = ch_multiqc_files.mix(FASTQ_TRIM_FASTP_FASTQC.out.trim_json.collect{it[1]})
        ch_multiqc_files = ch_multiqc_files.mix(FASTQ_TRIM_FASTP_FASTQC.out.fastqc_trim_zip.collect{it[1]})
        ch_fastq         = FASTQ_TRIM_FASTP_FASTQC.out.reads
    }
    if(params.run_nanopore_qc_trim) {
        FASTQ_NANOPORE_QC_TRIM (
            ch_fastq
        )
    }

    if (params.assemble_ref && host_fasta != null) {
        //
        // MODULE: Map raw reads to host
        //
        BWA_ALIGN_HOST (
            ch_fastq,
            ch_host_bwa_index.collect(),
            ch_host_fasta.collect(),
            "view"
        )
        ch_versions = ch_versions.mix(BWA_ALIGN_HOST.out.versions)
        ch_host_bam = BWA_ALIGN_HOST.out.bam

        //
        // SUBWORKFLOW: Sort, index BAM file and run samtools stats, flagstat and idxstats
        //
        BAM_HOST_SORT_STATS (
            ch_host_bam,
            ch_host_fasta.collect()
        )
        ch_versions           = ch_versions.mix(BAM_HOST_SORT_STATS.out.versions)
        ch_host_bam           = BAM_HOST_SORT_STATS.out.bam
        ch_host_bai           = BAM_HOST_SORT_STATS.out.bai
        ch_host_bam_stats     = BAM_HOST_SORT_STATS.out.stats
        ch_host_bams_flagstat = BAM_HOST_SORT_STATS.out.flagstat
        ch_host_bam_idxstats  = BAM_HOST_SORT_STATS.out.idxstats
        ch_multiqc_files      = ch_multiqc_files.mix(ch_host_bam_stats.collect{it[1]})
        ch_multiqc_files      = ch_multiqc_files.mix(ch_host_bams_flagstat.collect{it[1]})
        ch_multiqc_files      = ch_multiqc_files.mix(ch_host_bam_idxstats.collect{it[1]})

        //
        // CHANNEL: Combine bam and bai files
        //
        ch_host_bam_bai = ch_host_bam
        .map { row -> [row[0].id, row ].flatten()}
        .join ( ch_host_bai.map { row -> [row[0].id, row ].flatten()} )
        .map { row -> [row[1], row[2], row[4]] }

        //
        // MODULE: Filter for unmapped reads
        //
        SAMTOOLS_VIEW_HOST (
            ch_host_bam_bai,
            ch_host_fasta.collect(),
            []
        )
        ch_versions = ch_versions.mix(SAMTOOLS_VIEW_HOST.out.versions)
        ch_bam = SAMTOOLS_VIEW_HOST.out.bam

        //
        // MODULE: Sort by name
        //
        SAMTOOLS_SORT_VIRAL (
            ch_bam,
            [[],[]]
        )
        ch_versions = ch_versions.mix(SAMTOOLS_VIEW_HOST.out.versions)
        ch_bam = SAMTOOLS_SORT_VIRAL.out.bam

        //
        // MODULE: Convert to fastq
        //
        SAMTOOLS_FASTQ (
            ch_bam,
            false
        )
        ch_versions = ch_versions.mix(SAMTOOLS_FASTQ.out.versions)
        ch_fastq    = SAMTOOLS_FASTQ.out.fastq
    }

    ch_viral_ref = Channel.empty()
    ch_fastq_ref = Channel.empty()
    if(params.assemble_ref) {
        //
        // MODULE: First assembly of non-host reads
        //
        SPADES_ASSEMBLE (
            ch_fastq
        )
        // ch_versions = ch_versions.mix(SPADES_ASSEMBLE.out.versions)
        ch_contigs = SPADES_ASSEMBLE.out.contigs

        //
        // MODULE: Cluster contigs
        //
        CDHIT_CDHIT (
            ch_contigs
        )
        ch_versions          = ch_versions.mix(CDHIT_CDHIT.out.versions)
        ch_clustered_contigs = CDHIT_CDHIT.out.fasta

        //
        // MODULE: Filter small contigs
        //
        SEQTK_FASTA (
            ch_clustered_contigs
        )
        ch_versions         = ch_versions.mix(SEQTK_FASTA.out.versions)
        ch_filtered_contigs = SEQTK_FASTA.out.fasta

        //
        // MODULE: Build blastdb of viral segments
        //
        BLAST_MAKEBLASTDB (
            ch_viral_fasta
        )
        ch_versions      = ch_versions.mix(BLAST_MAKEBLASTDB.out.versions)
        ch_viral_blastdb = BLAST_MAKEBLASTDB.out.db

        //
        // MODULE: Blast contigs against viral segments
        //
        BLAST_BLASTN (
            ch_filtered_contigs,
            ch_viral_blastdb.collect()
        )
        ch_versions = ch_versions.mix(BLAST_BLASTN.out.versions)
        ch_blast    = BLAST_BLASTN.out.txt

        //
        // MODULE: Build reference fasta from top blast hits
        //
        BUILD_REFERENCE_FASTA (
            ch_viral_fasta,
            ch_blast
        )
        ch_viral_ref = BUILD_REFERENCE_FASTA.out.fasta

        //
        // CHANNEL: Join ref to reads
        //
        ch_fastq_ref = ch_fastq
        .map { [it[0].id, it ]}
        .join ( ch_viral_ref.map { [it[1].simpleName, it[1]] })
        .map{ [it[1][0], it[1][1], it[2]] }

        //
        // CHANNEL: Join ref to metadata
        //
        ch_viral_ref = ch_fastq
        .map { [it[0].id, it[0] ]}
        .join ( ch_viral_ref.map { [it[1].simpleName, it[1]] })
        .map{ [it[1], it[2]] }

    } else {
        ch_viral_ref = ch_viral_fasta
    }

    //
    // MODULE: Index ref
    //
    SAMTOOLS_FAIDX (
        ch_viral_ref,
        [[],[]]
    )
    ch_versions      = ch_versions.mix(SAMTOOLS_FAIDX.out.versions)
    ch_viral_ref_fai = SAMTOOLS_FAIDX.out.fai

    //
    // CHANNEL: Join ref to fai
    //
    ch_viral_ref_fasta_fai = ch_viral_ref
    .map { [it[0].id, it ]}
    .join ( ch_viral_ref_fai.map { [it[0].id, it[1]] })
    .map{ [it[1][0], it[1][1], it[2]] }

    ch_bam = Channel.empty()
    ch_bai = Channel.empty()
    if(params.run_iterative_align) {
        //
        // MODULE: Run iterative alignment
        //
        ITERATIVE_ALIGNMENT (
            ch_fastq_ref
        )
        ch_bam            = ITERATIVE_ALIGNMENT.out.bam
        ch_bai            = ITERATIVE_ALIGNMENT.out.bai
        ch_consensus_wref = ITERATIVE_ALIGNMENT.out.consensus_wref
        ch_consensus_wn   = ITERATIVE_ALIGNMENT.out.consensus_wn
        ch_final_ref      = ITERATIVE_ALIGNMENT.out.final_ref
        ch_align_metrics  = ITERATIVE_ALIGNMENT.out.metrics
    }
    // else if() {

    // }

    //
    // MODULE: Mark duplicates
    //
    PICARD_MARKDUPLICATES (
        ch_bam,
        [[],[]],
        [[],[]]
    )
    ch_versions      = ch_versions.mix(PICARD_MARKDUPLICATES.out.versions)
    ch_multiqc_files = ch_multiqc_files.mix(PICARD_MARKDUPLICATES.out.metrics.collect{it[1]})
    ch_bam           = PICARD_MARKDUPLICATES.out.bam

    //
    // SUBWORKFLOW: Sort, index BAM file and run samtools stats, flagstat and idxstats
    //
    BAM_VIRAL_SORT_STATS (
        ch_bam,
        [[],[]]
    )
    ch_versions      = ch_versions.mix(BAM_VIRAL_SORT_STATS.out.versions)
    ch_bam           = BAM_VIRAL_SORT_STATS.out.bam
    ch_bai           = BAM_VIRAL_SORT_STATS.out.bai
    ch_multiqc_files = ch_multiqc_files.mix(BAM_VIRAL_SORT_STATS.out.stats.collect{it[1]})
    ch_multiqc_files = ch_multiqc_files.mix(BAM_VIRAL_SORT_STATS.out.flagstat.collect{it[1]})
    ch_multiqc_files = ch_multiqc_files.mix(BAM_VIRAL_SORT_STATS.out.idxstats.collect{it[1]})

    //
    // CHANNEL: Join bam to bai and ref
    //
    ch_bam_bai_fasta_fai = ch_bam
    .map { [it[0].id, it ]}
    .join ( ch_bai.map { [it[0].id, it[1]] })
    .join ( ch_viral_ref_fasta_fai.map { [it[0].id, it[1], it[2]] })
    .map{ [it[1][0], it[1][1], it[2], it[3], it[4]] }

    // if(params.soft_clip_primers && params.primers_fasta && params.primers_csv) {
        //
        // SUBWORKFLOW: Prepare primers
        //
        // PREPARE_PRIMERS (
        //     ch_viral_ref,
        //     file(params.primers_fasta),
        //     file(params.primers_csv)
        // )
        // ch_versions = ch_versions.mix(PREPARE_PRIMERS.out.versions)

        
        //MODULE: Run ivar trim
        // IVAR_TRIM (

        // )
        // ch_versions = ch_versions.mix(IVAR_TRIM.out.versions)
    // }

    //
    // MODULE: Call variants
    //
    LOFREQ_CALL (
        ch_bam_bai_fasta_fai.map{[it[0], it[1], it[2]]},
        ch_bam_bai_fasta_fai.map{[it[0], it[3], it[4]]},
    )

    //
    // MODULE: Genome-wide coverage
    //
    MOSDEPTH (
        ch_bam_bai_fasta_fai.map{[it[0], it[1], it[2], []]},
        ch_bam_bai_fasta_fai.map{[it[0], it[3]]},
    )
    ch_versions      = ch_versions.mix(MOSDEPTH.out.versions)
    ch_multiqc_files = ch_multiqc_files.mix(MOSDEPTH.out.global_txt.collect{it[1]})

    // TODO
    //
    // CHANNEL: Collect topic versions
    //
    // ch_topic_versions = Channel.topic('versions') 
//     | unique()
//     | map { process, name, version ->
//       """\
//       ${process.tokenize(':').last()}:
//         ${name}: ${version}
//       """.stripIndent()
//     

    //
    // MODULE: Track software versions
    //
    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile()
    )

    //
    // MODULE: MULTIQC
    //
    workflow_summary = multiqc_summary(workflow, params)
    ch_workflow_summary = Channel.value(workflow_summary)
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_unique_yml.collect())

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config,
        [],
        ch_multiqc_logo
    )
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
