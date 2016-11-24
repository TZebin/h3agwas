#!/usr/bin/env nextflow

/*
 * Authors       :
 *
 *
 *      Shaun Aron
 *   	Rob Clucas
 *      Eugene de Beste
 *      Scott Hazelhurst
 *      Anmol Kiran
 *      Lerato Magosi
 *      Abayomi Mosaku
 *
 *  On behalf of the H3ABionet Consortium
 *  2015-2016
 *
 *
 * Description  : Nextflow pipeline for Wits GWAS.
 *
 */

//---- General definitions --------------------------------------------------//

import java.nio.file.Paths;
import sun.nio.fs.UnixPath;

def helps = [ 'help' : 'help' ]


def params_help = new LinkedHashMap(helps)



max_plink_cores = params.max_plink_cores 

plink_mem_req = params.plink_process_memory
other_mem_req = params.other_process_memory
pi_hat=params.pi_hat

if (params.help) {
    params.each {
    entry ->
      print "Parameter: <$entry.key>    \t Default: $entry.value"
      if (entry.key == 'help')
          println ""
      else {
        help = params_help.get(entry.key)
        if (help)
          print "\n    $help"
        println ""
      }
  }
  System.exit(-1)
}

//---- Modification of variables for pipeline -------------------------------//

/* Define the command to add for plink depending on whether sexinfo is
 * available or not.
 */
if ( params.sexinfo_available == "false" ) {
  sexinfo = "--allow-no-sex"
  println "Sexinfo not available, command --allow-no-sex\n"
} else {
  sexinfo = ""
  println "Sexinfo available command"
}


// Checks if the file exists
checker = { fn ->
   if (fn.exists())
       return fn;
    else
       error("\n\n-----------------\nFile $fn does not exist\n\n---\n")
}


//------------


raw_ch = Channel.create()
bim_ch = Channel.create()

/* Get the input files -- could be a glob
 * We match the bed, bim, fam file -- order determined lexicographically
 * not by order given, we check that they exist and then 
 * send the all the files to raw_ch and just the bim file to bim_ch */



Channel
   .fromFilePairs("${params.input_dir}/*.{bed,bim,fam}",size:3, flat : true)\
   .ifEmpty { error "No matching plink files" }\
   .map { a -> [checker(a[1]), checker(a[2]), checker(a[3])] }\
   .separate(raw_ch, bim_ch) { a -> [a,a[1]] }



//---- Start Pipeline -------------------------------------------------------//

/* Process to find duplicates. *
 * Inputs:
 * - bim: the bim file
 * Outputs:
 * - duplicates.snps    : A possibly empty file with a list of SNPs
 */
process getDuplicateMarkers {
  memory other_mem_req
  input:
    set file(inpfname) from bim_ch
  output:
    set  file("${base}.dups") into duplicates_ch
  script:
     print inpfname
     base = inpfname.baseName
     outfname = "${base}.dups"
     template "dups.py"
}


public String getBase(fn) {
   x = file("tmp")
   if (fn.getClass() == x.getClass())
      return fn.getBaseName();
   else
      return fn[0].getBaseName();
}	


/*  Process to remove duplicate SNPs.
 * Inputs
 *   -  raw files from from user-specified data
 *   -  list of duplicates comes from getDuplicateMarkers
 * Outputs:
 *   nodups.{bed,bim,fam} (PLINK file without duplicates) and
 *   qc.log log file
 */

process removeDuplicateSNPs {
  memory plink_mem_req
  input:
    set file(plinks), file(duplicates)	\
    from raw_ch.phase(duplicates_ch){getBase(it) }

  publishDir params.output_dir, pattern: "0002-dups.log", \
             overwrite:true, mode:'copy'

  output:
    set  file('${base}-nd.bed'),file('${base}-nd.bim'),file('${base}-nd.fam') \
         into (sex_check_ch,missing_ch,het_ch,ibd_prune_ch,remove_inds_ch)
    file ('${base}-0002-dups.log')
  script:
   bed = plinks[0].baseN
   base=bed.baseName
   """
    plink --bfile ${base} $sexinfo --exclude duplicates.snps --make-bed --out nodups >> qc.log
    mv nodups.log ${base}-0002-dups.log
   """
}





/* Process to identify individual discordant sex information.
 * results are put in the output directory
 */
process identifyIndivDiscSexinfo {
  memory other_mem_req
  input:
     set file('nodups.bed'),file('nodups.bim'),file('nodups.fam') from sex_check_ch

  publishDir params.output_dir, overwrite:true, mode:'copy'

  output:
     file '0010-failed.sexcheck' into failed_sex_check
  script:
  if (params.sexinfo_available == "true")
  """
       plink --bfile nodups --check-sex  --out nodups
       if grep -Rn 'PROBLEM' nodups.sexcheck > 0010-failed.sexcheck; then
         echo 'Discordant sex info found'
       else
         echo 'No discordant sex info found'
       fi

  """
  else
    "echo 'No sex information available to check'  > 0010-failed.sexcheck"

}


// Find missingness statistics for the plink file
process calculateSampleMissing {
  memory plink_mem_req
  input:
     set file('nodups.bed'),file('nodups.bim'),file('nodups.fam') from missing_ch

  publishDir params.output_dir, overwrite:true, mode:'copy'

  output:
     file("0020.imiss") into (plot1_ch_miss,missing2_ch,miss_het_ch)
  """
    plink --bfile nodups $sexinfo --missing --out 0020
  """
}



// But for the  moment let's deal with heterozygosity

process calculateSampleHetrozygosity {
   memory plink_mem_req
   input:
      set file('nodups.bed'),file('nodups.bim'),file('nodups.fam') from het_ch

   publishDir params.output_dir, overwrite:true, mode:'copy'

   output:
      file("0030.het") into (hetero_check_ch, plot1_ch_het)
   script:
   """
     plink --bfile nodups $sexinfo --het  --out 0030
   """
}



process generateMissHetPlot {
  memory other_mem_req
  errorStrategy 'ignore'

  input:
    file 'qcplink.imiss' from plot1_ch_miss
    file 'qcplink.het'   from plot1_ch_het
  publishDir params.output_dir, overwrite:true, mode:'copy', pattern: "*.pdf"

  output:
    file('*.pdf')   into pictures_ch

  script:
    imiss   = "qcplink.imiss"
    het     = "qcplink.het"
    pairs   = "pairs.imiss-vs-het.pdf"
    meanhet = "meanhet_plot.pdf"
    template "miss_het_plot_qcplink.R"
}



// Find those who have too high missingness, or bad heterozygosity
process getBadIndivs_Missing_Het {
  errorStrategy 'ignore'
  memory other_mem_req
  input:
   file 'qcplink.imiss' from miss_het_ch
   file 'qcplink.het'   from hetero_check_ch
  output:
    file('fail_miss_het_qcplink.txt') into failed_miss_het

  script:
    outfname = "fail_miss_het_qcplink.txt"
    template "select_miss_het_qcplink.pl"

}

/* We are going to check for related individuals and remove them */

// first, in computing relatedness do we ignore high LD regions?

if (params.high_ld_regions_fname != "")
   ldreg_ch=Channel.fromPath(params.plink_inputpath+params.high_ld_regions_fname)
else
   ldreg_ch=Channel.value("dummy") //If not, create dummy channel



// Get which SNPs should be pruned for IBD
process pruneForIBD {
	// multi-threaded plink -- probably 2 core optimal, maybe 3
  cpus max_plink_cores
  memory plink_mem_req
  input:
    set file('nodups.bed'),file('nodups.bim'),file('nodups.fam') from ibd_prune_ch
    file ldreg    from ldreg_ch
  output:
  //set file('nodups.bed'),file('nodups.bim'),file('nodups.fam') into ibd
    file 'ibd_min_thresh.genome' into sort_ibd_ch1,sort_ibd_ch2
  script:
    if (params.high_ld_regions_fname != "")
      range = "--range --exclude $ldreg"
    else
      range =""
    """
      plink --bfile nodups --threads $max_plink_cores --autosome $sexinfo $range --indep-pairwise 50 5 0.2 --out ibd
      plink --bfile nodups --threads $max_plink_cores --autosome $sexinfo --extract ibd.prune.in --genome --out ibd_prune
      plink --bfile nodups --threads $max_plink_cores --autosome $sexinfo --extract ibd.prune.in --genome --min $pi_hat --out ibd_min_thresh
      echo DONE
     """

}



// run script to find related individuals
//  Future - perhaps replaced with Primus
process findRelatedIndiv {
  errorStrategy 'ignore'
  memory other_mem_req
  input:
     file missing    from missing2_ch
     file ibd_genome from sort_ibd_ch2

  output:
     file 'fail_IBD_qcplink.txt' into related_indivs

  script:
     outfname = "fail_IBD_qcplink.txt"
     template "run_IBD_QC_qcplink.pl"


}


process removeQCIndivs {
  memory plink_mem_req
  input:
    file failed_miss_het
    file failed_sexcheck_f from failed_sex_check
    file related_indivs
    set file('nodups.bed'),file('nodups.bim'),file('nodups.fam') from remove_inds_ch
  output:
     set file("clean00.bed"),file("clean00.bim"),file("clean00.fam") into \
         (clean00_ch1,clean00_ch2,clean00_ch3, clean00_ch4)

  script:
  """
  cat $failed_sexcheck_f $related_indivs $failed_miss_het | sort -k1 | uniq > qcplink_failed_inds
  plink --bfile nodups $sexinfo --remove qcplink_failed_inds --make-bed --out clean00
  """
}



process calculateMaf {
  memory plink_mem_req
  input:
    set file("clean00.bed"),file("clean00.bim"),file("clean00.fam") from clean00_ch1

  publishDir params.output_dir, overwrite:true, mode:'copy', pattern: "*.frq"

  output:
    file 'clean00.frq' into maf_plot_ch

  script:
  """
    plink --bfile clean00 $sexinfo  --freq --out clean00
  """
}


process generateMafPlot {
  memory other_mem_req
  input:
    file 'clean00.frq' from maf_plot_ch
  publishDir params.output_dir, overwrite:true, mode:'copy', pattern: "*.pdf"

  output:
    file 'maf_plot.pdf'

  script:
    frqfile = "clean00.frq"
    ofname  = "maf_plot.pdf"
    template "maf_plot_qcplink.R"
}


// Repeat computation of missingness on QCd data
process calculateSnpMissigness {
  memory plink_mem_req
  input:
   set file('clean00.bed'),file('clean00.bim'),file('clean00.fam')  from clean00_ch2

  output:
   file 'clean00.lmiss' into clean_miss_plot_ch

  script:
  """
   plink --bfile clean00 $sexinfo --missing --out clean00
  """
}


process generateSnpMissingnessPlot {
  memory other_mem_req
  input:
    file 'clean00.lmiss' from clean_miss_plot_ch

  publishDir params.output_dir, overwrite:true, mode:'copy', pattern: "*.pdf"

  output:
    file 'snpmiss_plot.pdf'

  script:
    input  = "clean00.lmiss"
    output = "snpmiss_plot.pdf"
    template "snpmiss_plot_qcplink.R"
}

// Find differential missingness between cases and controls; also compute HWE scores
process calculateSnpSkewStatus {
  memory plink_mem_req
  cpus max_plink_cores
  input:
    set file('clean00.bed'),file('clean00.bim'),file('clean00.fam')  from clean00_ch3
  output:
    file 'clean00.missing' into (clean_diff_miss_plot_ch1,clean_diff_miss_ch2)
    file 'clean00.hwe' into hwe_scores_ch
  script:
   """
    plink --threads ${max_plink_cores} --bfile clean00 $sexinfo --test-missing mperm=20000 --hardy --out clean00
   """
}


process generateDifferentialMissingnessPlot {
   memory other_mem_req
   input:
     file "clean00.missing" from clean_diff_miss_plot_ch1
   publishDir params.output_dir, overwrite:true, mode:'copy', pattern: "*.pdf"
   output:
      file 'snpmiss_plot.pdf' into snpmiss_plot_ch
   script:
       input = "clean00.missing"
       output= "snpmiss_plot.pdf"
       template "diffmiss_splot_qcplink.R"

 }


// Find those SNPs that have diff missingness in cases & controls
process findSnpExtremeDifferentialMissingness {
  memory other_mem_req
  input:
    file "clean00.missing" from clean_diff_miss_ch2
  output:
     file 'failed_diffmiss.snps' into bad_snps_ch
  script:
    cut_diff_miss=params.cut_diff_miss
    missing = "clean00.missing"
    failed  = "failed_diffmiss.snps"
    template "select_diffmiss_qcplink.pl"
}

// Find HWE scores of each SNP
process findHWEofSNPs {
  memory other_mem_req
  input:
     file 'clean00.hwe' from hwe_scores_ch
  output:
     file 'unaff.hwe'   into unaff_hwe

  script:
  """
   head -1 clean00.hwe > unaff.hwe
   grep 'UNAFF' clean00.hwe >> unaff.hwe
  """
}

process generateHwePlot {
  memory other_mem_req
  input:
    file 'unaff.hwe' from unaff_hwe
  publishDir params.output_dir, overwrite:true, mode:'copy', pattern: "*.pdf"
  output:
    file 'hwe_plot.pdf'

  script:
    input  = "unaff.hwe"
    output = "hwe_plot.pdf"
    template "hwe_plot_qcplink.R"
}


process removeQCPhase1 {
  memory plink_mem_req
  input:
    set file('clean00.bed'),file('clean00.bim'),file('clean00.fam')  from clean00_ch4
    file 'failed_diffmiss.snps' from bad_snps_ch
  publishDir params.output_dir, overwrite:true, mode:'copy'
  output:
    set file('cleaned.bed'),file('cleaned.bim'),file('cleaned.fam')  into \
       result_ch;

  script:
  """
  # remove really realy bad SNPs and really bad individuals
  plink --bfile clean00 $sexinfo --exclude failed_diffmiss.snps --mind 0.2 --make-bed --out temp1
  # remove bad SNPs
  plink --bfile temp1 $sexinfo --geno 0.2 --make-bed --out temp2
  # Now do final QC
  plink --bfile temp2  $sexinfo \
        --autosome \
        --maf $params.cut_maf --mind $params.cut_mind --geno $params.cut_geno --hwe $params.cut_hwe \
         --make-bed --out ${params.output}
  """
}


result_ch.subscribe { print "Completed and produced ${it.baseName}" }
