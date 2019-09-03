library(data.table)
library(dplyr)
library(tidyr)
library(ggplot2)
library(stringi)

###############################
# LINX RNA-DNA FUSION ANALYSIS

annotate_fusions<-function(fusionData)
{
  fusionData = fusionData %>% mutate(SameSV = (SvIdUp==SvIdDown))
  
  # chaining info
  fusionData = fusionData %>% separate(ChainInfo,c('ChainId','ChainLinks','ChainLength','ValidTraversal','TraversalAssembled'),sep = ';')
  fusionData$ChainLength = as.numeric(fusionData$ChainLength)
  fusionData$ChainLinks = as.numeric(fusionData$ChainLinks)
  fusionData$InChain = (fusionData$ChainId>=0)
  
  # chain & cluster validity
  fusionData = fusionData %>% separate(OverlapUp,c('FacingBEsUp','AssembledLinksUp','TotalBEsUp','FacingDistanceUp','DisruptedExonsUp','TerminatedUp'),sep = ';')
  fusionData$FacingBEsUp = as.numeric(fusionData$FacingBEsUp)
  fusionData$TotalBEsUp = as.numeric(fusionData$TotalBEsUp)
  fusionData$FacingDistanceUp = as.numeric(fusionData$FacingDistanceUp)
  fusionData$TerminatedUp = !is.na(fusionData$TerminatedUp) & fusionData$TerminatedUp=='true'
  
  fusionData = fusionData %>% separate(OverlapDown,c('FacingBEsDown','AssembledLinksDown','TotalBEsDown','FacingDistanceDown','DisruptedExonsDown','TerminatedDown'),sep = ';')
  fusionData$FacingBEsDown = as.numeric(fusionData$FacingBEsDown)
  fusionData$TotalBEsDown = as.numeric(fusionData$TotalBEsDown)
  fusionData$FacingDistanceDown = as.numeric(fusionData$FacingDistanceDown)
  fusionData$TerminatedDown = !is.na(fusionData$TerminatedDown) & fusionData$TerminatedDown=='true'
  
  fusionData = (fusionData %>% 
                  mutate(ValidChain=ValidTraversal=='true'&DisruptedExonsUp==0&DisruptedExonsDown==0&TerminatedUp=='false'&TerminatedDown=='false',
                         NonDisruptedSingle=FacingBEsUp==0&FacingBEsDown==0&DisruptedExonsUp==0&DisruptedExonsDown==0,
                         BreakendDistUp=ifelse(StrandUp==1,TransStartUp-PosUp,PosUp-TransEndUp),
                         BreakendDistDown=ifelse(StrandUp==1,TransStartDown-PosDown,PosDown-TransEndDown)))
  
  fusionData[is.na(fusionData)] = 0
  
  return (fusionData)
}

load_rna_match_data<-function(filename)
{
  rnaMatchData = read.csv(filename)
  
  #Annotations
  rnaMatchData = rnaMatchData %>% mutate(SvMatchUp=!is.na(SvIdUp)&TransValidLocUp=='true',
                                         SvMatchDown=!is.na(SvIdDown)&TransValidLocDown=='true',
                                         SvViableUp=TransViableUp=='true',
                                         SvViableDown=TransViableDown=='true',
                                         SvValidLocUp=TransValidLocUp=='true',
                                         SvValidLocDown=TransValidLocDown=='true',
                                         SameSV=SvIdUp==SvIdDown,
                                         SameChr=ChrUp==ChrDown,
                                         FusionDistance=ifelse(SameChr,StrandUp*(RnaPosDown-RnaPosUp),0),
                                         Proximate=FusionDistance>0&FusionDistance<5e5)
  
  rnaMatchData$SvMatchType = ifelse(rnaMatchData$SvMatchUp&rnaMatchData$SvMatchDown,'BothSVs',
                                    ifelse(rnaMatchData$SvMatchUp|rnaMatchData$SvMatchDown,'SingleSV','NoSV'))
  
  # DEDUP 
  rnaMatchData = rnaMatchData %>% group_by(SampleId,FusionName) %>% arrange(-JunctionReadCount,-SpanningFragCount) %>% filter(row_number()==1) %>% ungroup() 
  rnaMatchData = rnaMatchData %>% group_by(SampleId,RnaPosUp,RnaPosDown) %>% arrange(-JunctionReadCount,-SpanningFragCount) %>% filter(row_number()==1) %>% ungroup() 
  
  # PON: Remove recurrent fusions where NONE have SV support at both ends
  # rnaMatchData = rnaMatchData %>% group_by(FusionName) %>% filter(!((sum(ifelse(SvMatchType=='NoSV',1,0))>1&(sum(ifelse(SvMatchType=='BothSVs',1,0))<1)))) %>% ungroup()
  rnaMatchData = rnaMatchData %>% group_by(FusionName) %>% 
    filter(!((sum(ifelse(SvMatchType=='NoSV',1,0))>1&sum(ifelse(SvMatchType=='BothSVs',1,0))<pmax(1,sum(ifelse(SvMatchType=='NoSV',1,0))-1)))) %>% ungroup()
  
  rnaBothSVsData = rnaMatchData %>% filter(SvMatchType=='BothSVs')
  rnaNotBothSVsData = rnaMatchData %>% filter(SvMatchType!='BothSVs')
  
  rnaBothSVsData = rnaBothSVsData %>% separate(ClusterInfoUp,c('ClusterIdUp','ClusterCountUp','ChainIdUp','ChainCountUp'),sep = ';')
  rnaBothSVsData = rnaBothSVsData %>% separate(ClusterInfoDown,c('ClusterIdDown','ClusterCountDown','ChainIdDown','ChainCountDown'),sep = ';')
  
  rnaBothSVsData = rnaBothSVsData %>% mutate(SameCluster=(ClusterIdUp==ClusterIdDown),
                                             SameChain=ifelse(SameSV,T,SameCluster&ChainIdUp==ChainIdDown))
  
  rnaNotBothSVsData = rnaNotBothSVsData %>% mutate(SameCluster=F,
                                                   SameChain=F,
                                                   ClusterIdUp=-1,ClusterCountUp=0,ChainIdUp=-1,ChainCountUp=0,
                                                   ClusterIdDown=-1,ClusterCountDown=0,ChainIdDown=-1,ChainCountDown=0)
  
  rnaNotBothSVsData = within(rnaNotBothSVsData,rm(ClusterInfoUp))
  rnaNotBothSVsData = within(rnaNotBothSVsData,rm(ClusterInfoDown))
  
  
  rnaMatchData = rbind(rnaBothSVsData,rnaNotBothSVsData)
  
  return (rnaMatchData)
}

annotate_rna_both_svs<-function(rnaMatchData)
{
  rnaBothSVsData = rnaMatchData %>% filter(SvMatchType=='BothSVs')
  
  # rnaBothSVsData = rnaBothSVsData %>% separate(ClusterInfoUp,c('ClusterIdUp','ClusterCountUp','ChainIdUp','ChainCountUp'),sep = ';')
  # rnaBothSVsData = rnaBothSVsData %>% separate(ClusterInfoDown,c('ClusterIdDown','ClusterCountDown','ChainIdDown','ChainCountDown'),sep = ';')
  
  rnaBothSVsData$ClusterCountUp = as.numeric(rnaBothSVsData$ClusterCountUp)
  rnaBothSVsData$ClusterCountDown = as.numeric(rnaBothSVsData$ClusterCountDown)
  rnaBothSVsData$ChainCountUp = as.numeric(rnaBothSVsData$ChainCountUp)
  rnaBothSVsData$ChainCountDown = as.numeric(rnaBothSVsData$ChainCountDown)
  
  rnaBothSVsData$IsChainedUp = (rnaBothSVsData$ChainCountUp>1)
  rnaBothSVsData$IsChainedDown = (rnaBothSVsData$ChainCountDown>1)
  
  rnaBothSVsData = rnaBothSVsData %>% separate(ChainInfo,c('ChainLinks','ChainLength'),sep = ';')
  rnaBothSVsData$ChainLength = as.numeric(rnaBothSVsData$ChainLength)
  rnaBothSVsData$ChainLinks = as.numeric(rnaBothSVsData$ChainLinks)
  
  rnaBothSVsData$ChainLength = as.numeric(rnaBothSVsData$ChainLength)
  rnaBothSVsData$ChainLinks = as.numeric(rnaBothSVsData$ChainLinks)
  
  rnaBothSVsData$FacingInChain = (rnaBothSVsData$ChainLength>0)
  
  return (rnaBothSVsData)
}

known_type_category<-function(knownType)
{
  newKnownType = ifelse(knownType=='Known','Known',ifelse(knownType=='5P-Prom'|knownType=='3P-Prom'|knownType=='Both-Prom','Promiscuous','Unknown'))
  return (newKnownType)
}


#####################
# RNA Summary results

# 1. RNA / DNA Sensitivity
# using RNA Match Data only

hpcDedupedSamples = read.csv('~/data/sv/hpc_non_dup_sample_ids.csv')

rnaMatchData = load_rna_match_data('~/data/sv/rna/SVA_RNA_DATA.csv')

# restrict to HPC deduped cohort
rnaMatchData = rnaMatchData %>% filter(RnaPhaseMatched=='true')

# filter out unphased RNA fusions for all subsequent analysis
rnaMatchData = rnaMatchData %>% filter(SampleId %in% hpcDedupedSamples$sampleId)

rnaMatchDataBothSVs = annotate_rna_both_svs(rnaMatchData)

summaryBothData = rnaMatchDataBothSVs %>% 
  mutate(SvaCategory=ifelse(SameCluster&SameChain,'Matched',ifelse(SameCluster&!SameChain,'DiffChain','DiffCluster')),
         ValidBreakends=SvViableUp&SvViableDown,
         ViableFusion=ViableFusion=='true',
         PhaseMatched=PhaseMatched=='true',
         RnaPhaseMatched=RnaPhaseMatched=='true',
         SameSV=SameSV)

summaryNotBothData = rnaMatchData %>% filter(SvMatchType!='BothSVs') %>% 
  mutate(SvaCategory = ifelse(SvMatchType=='SingleSV','SingleBEMatch','NoMatch'),
         ValidBreakends=F,
         ViableFusion=F,
         PhaseMatched=F,
         RnaPhaseMatched=RnaPhaseMatched=='true',
         SameSV=T)

summaryRnaData = rbind(summaryBothData %>% select(KnownType,SvaCategory,ValidBreakends,ViableFusion,PhaseMatched,RnaPhaseMatched,SameSV),
                       summaryNotBothData %>% select(KnownType,SvaCategory,ValidBreakends,ViableFusion,PhaseMatched,RnaPhaseMatched,SameSV))

summaryRnaData = summaryRnaData %>% 
  mutate(SvaCategory2=ifelse(SvaCategory=='Matched',ifelse(ValidBreakends,'Matched','MatchedExonsSkipped'),
                             ifelse(RnaPhaseMatched,'NotCalled','NoRnaPhasedFusion')),
         FusionType=known_type_category(KnownType))

summaryRnaData$FusionType = "AllFusions" # no split by KnownType

rnaCategorySummary1 = summaryRnaData %>% group_by(SvaCategory2,FusionType) %>% count() %>% spread(SvaCategory2,n) %>% 
  arrange(FusionType) %>% ungroup()
rnaCategorySummary1[is.na(rnaCategorySummary1)] = 0

rnaCategorySummaryData1 = rnaCategorySummary1 %>% select(FusionType,Matched,MatchedExonsSkipped,NotCalled)
rnaCategorySummaryData1 = rnaCategorySummaryData1 %>% gather('Category','Count', 2:ncol(rnaCategorySummaryData1)) 

rnaCategorySummaryData1 = merge(rnaCategorySummaryData1,catData,by='Category',all.x=T)

plotColours3 = c('royal blue','light blue','orangered','sienna1','khaki4','khaki3','palegreen', 'seagreen')

rnaSummaryDataPlot1 = (ggplot(rnaCategorySummaryData1, aes(x=FusionType, y=Count, fill=Category))
                       + geom_bar(stat = "identity", colour = "black", position = position_stack(reverse = TRUE))
                       + labs(x='',y="Fusion Count", fill='Category', title='Fusion Sensitivity')
                       + scale_fill_manual(values = plotColours3)
                       + theme_bw() + theme(panel.grid.minor.x = element_blank(), panel.grid.major.x = element_blank())
                       + theme(panel.grid.minor.y = element_blank(), panel.grid.major.y = element_blank())
                       + theme(axis.text.x = element_text(angle=90, hjust=1,size=10))
                       + coord_flip())

## PLOT 1: LINX Fusion Sensitivity

plot(rnaSummaryDataPlot1)




###############################
# Matching with SVA Fusion data
# 'Precision' report

# load all fusions found for the 630 samples with RNA
svaRnaFusions = read.csv('~/data/sv/rna/SVA_FUSIONS.csv')
svaRnaFusions = annotate_fusions(svaRnaFusions)
svaRnaFusions = svaRnaFusions %>% filter(SampleId %in% hpcDedupedSamples$sampleId)

rnaReadData = load_rna_match_data('~/data/sv/rna/read_data/SVA_RNA_READ_DATA.csv')
rnaReadData = rnaReadData %>% mutate(SampleGenePair=paste(SampleId,GeneNameUp,GeneNameDown,sep='_'))


# create a combined file from the RNA and LINX fusions files
rnaCombinedData = merge(svaRnaFusions, 
                        rnaMatchData %>% filter(RnaPhaseMatched=='true'),
                        by=c('SampleId','GeneNameUp','GeneNameDown'),all=T)

rnaCombinedData = rnaCombinedData %>% mutate(HasDnaData=!is.na(KnownType.x),
                                             HasRnaData=!is.na(KnownType.y),
                                             SampleGenePair=paste(SampleId,GeneNameUp,GeneNameDown,sep='_'))

rnaCombinedData = rnaCombinedData %>% mutate(HasReadSupport=(HasDnaData&!HasRnaData&SampleGenePair %in% rnaReadData$SampleGenePair))

dnaRnaCombinedData = rnaCombinedData %>% 
  mutate(KnownType=ifelse(!is.na(KnownType.x),as.character(KnownType.x),as.character(KnownType.y)),
         ChrUp=ifelse(!is.na(ChrUp.x),ChrUp.x,ChrDown.y),ChrDown=ifelse(!is.na(ChrDown.x),ChrDown.x,ChrDown.y),
         PosUp=ifelse(!is.na(PosUp.x),PosUp.x,PosUp.y),PosDown=ifelse(!is.na(PosDown.x),PosDown.x,PosDown.y),
         OrientUp=ifelse(!is.na(OrientUp.x),OrientUp.x,OrientUp.y),OrientDown=ifelse(!is.na(OrientDown.x),OrientDown.x,OrientDown.y),
         StrandUp=ifelse(!is.na(StrandUp.x),StrandUp.x,StrandUp.y),StrandDown=ifelse(!is.na(StrandDown.x),StrandDown.x,StrandDown.y),
         RnaPosUp,RnaPosDown,TransValidLocUp,TransViableUp,TransValidLocDown,TransViableDown,
         TransIdUp=ifelse(!is.na(TranscriptUp),as.character(TranscriptUp),as.character(TransIdUp)),
         CodingTypeUp=ifelse(!is.na(CodingTypeUp.x),as.character(CodingTypeUp.x),as.character(CodingTypeUp.y)),
         RegionTypeUp=ifelse(!is.na(RegionTypeUp.x),as.character(RegionTypeUp.x),as.character(RegionTypeUp.y)),
         SameSV=ifelse(!is.na(SameSV.x),SameSV.x,SameSV.y),
         SameCluster=ifelse(is.na(SameCluster),T,SameCluster),SameChain=ifelse(is.na(SameChain),T,SameChain)) %>%
  mutate(Category=ifelse(HasRnaData&!HasDnaData&SvMatchType!='BothSVs','RNA Only',
                         ifelse(HasReadSupport,'DNA with RNA Read Support',
                                ifelse(HasDnaData&!HasRnaData,'DNA Only',
                                       ifelse(HasDnaData|(SameCluster&SameChain),'DNA & RNA','RNA with DNA Support')))),
         KnownCategory=known_type_category(KnownType))

write.csv(dnaRnaCombinedData,'~/data/sv/rna/dnaRnaCombinedData_hpc_dedup.csv', quote = F, row.names = F)

# create a summary view to plot the precision results
dnaRnaSummary = dnaRnaCombinedData %>% filter(KnownCategory!='Unknown') %>%
  mutate(MatchType=ifelse(Category=='DNA & RNA','DNA & RNA',
                          ifelse(Category=='DNA Only'|Category=='DNA with RNA Read Support','DNA Only','RNA Only'))) %>%
  group_by(MatchType,KnownType) %>% count()

plotColours4 = c('royal blue','skyblue3','lightblue','khaki4','khaki3','sienna1')

dnaRnaSummaryPlot = (ggplot(dnaRnaSummary, aes(x=KnownType, y=n, fill=MatchType))
                     + geom_bar(stat = "identity", colour = "black", position = position_stack(reverse = TRUE))
                     + labs(x = "", y="Fusion Count", fill='Match Category', title = "DNA vs RNA Fusion Prediction")
                     + scale_fill_manual(values = plotColours4)
                     + theme_bw() + theme(panel.grid.minor.x = element_blank(), panel.grid.major.x = element_blank())
                     + theme(panel.grid.minor.y = element_blank(), panel.grid.major.y = element_blank())
                     + theme(axis.text.x = element_text(angle=90, hjust=1,size=10))
                     + coord_flip())

## PLOT 2: DNA vs RNA Fusion Prediction

plot(dnaRnaSummaryPlot)
