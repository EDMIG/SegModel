#include "caffe/layers/activation/pooling_layer.hpp"

namespace caffe {

template <typename Dtype>
static __global__ void MaxPoolForward(const int nthreads, const Dtype* bottom_data,
    const int num, const int channels, const int height, const int width, const int pooled_height, const int pooled_width,
    const int kernel_h, const int kernel_w, const int stride_h, const int stride_w, const int pad_h, const int pad_w, 
    Dtype* top_data, int* mask) 
{
  CUDA_KERNEL_LOOP(index, nthreads) 
  {
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int n = index / pooled_width / pooled_height / channels;
    int hstart = ph * stride_h - pad_h;
    int wstart = pw * stride_w - pad_w;
    int hend = min(hstart + kernel_h, height);
    int wend = min(wstart + kernel_w, width);
    hstart = max(hstart, 0);
    wstart = max(wstart, 0);
    Dtype maxval = -FLT_MAX;
    int maxidx = -1;
    bottom_data += (n * channels + c) * height * width;
    for (int h = hstart; h < hend; ++h) 
      for (int w = wstart; w < wend; ++w) 
        if (bottom_data[h * width + w] > maxval) 
        {
          maxidx = h * width + w;
          maxval = bottom_data[maxidx];
        }
      
    
    top_data[index] = maxval;   
    mask[index] = maxidx;    
  }
}

template <typename Dtype>
static __global__ void AvePoolForward(const int nthreads, const Dtype* bottom_data,
    const int num, const int channels, const int height, const int width, const int pooled_height, const int pooled_width,
    const int kernel_h, const int kernel_w, const int stride_h, const int stride_w, const int pad_h, const int pad_w, 
    Dtype* top_data) 
{
  CUDA_KERNEL_LOOP(index, nthreads) 
  {
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int n = index / pooled_width / pooled_height / channels;
    int hstart = ph * stride_h - pad_h;
    int wstart = pw * stride_w - pad_w;
    int hend = min(hstart + kernel_h, height + pad_h);
    int wend = min(wstart + kernel_w, width + pad_w);
    int pool_size = (hend - hstart) * (wend - wstart);
    hstart = max(hstart, 0);
    wstart = max(wstart, 0);
    hend = min(hend, height);
    wend = min(wend, width);
    Dtype aveval = 0;
    bottom_data += (n * channels + c) * height * width;
    for (int h = hstart; h < hend; ++h) 
      for (int w = wstart; w < wend; ++w) 
        aveval += bottom_data[h * width + w];


    top_data[index] = aveval / pool_size;
  }
}

template <typename Dtype>
static __global__ void MaxPoolBackward(const int nthreads, const Dtype* top_diff, const int* mask, 
		const int num, const int channels, const int height, const int width, const int pooled_height, const int pooled_width, 
		const int kernel_h, const int kernel_w, const int stride_h, const int stride_w, const int pad_h, const int pad_w,
    Dtype* bottom_diff) 
{
  CUDA_KERNEL_LOOP(index, nthreads) 
	{
    // find out the local index
    // find out the local offset
    int w = index % width;
    int h = (index / width) % height;
    int c = (index / width / height) % channels;
    int n = index / width / height / channels;
    int phstart =
        (h + pad_h < kernel_h) ? 0 : (h + pad_h - kernel_h) / stride_h + 1;
    int phend = min((h + pad_h) / stride_h + 1, pooled_height);
    int pwstart =
        (w + pad_w < kernel_w) ? 0 : (w + pad_w - kernel_w) / stride_w + 1;
    int pwend = min((w + pad_w) / stride_w + 1, pooled_width);
    Dtype gradient = 0;
    int offset = (n * channels + c) * pooled_height * pooled_width;
    top_diff += offset;
  
    mask += offset;
    for (int ph = phstart; ph < phend; ++ph) 
      for (int pw = pwstart; pw < pwend; ++pw) 
        if (mask[ph * pooled_width + pw] == h * width + w) 
          gradient += top_diff[ph * pooled_width + pw];



    
    bottom_diff[index] = gradient;
  }
}

template <typename Dtype>
static __global__ void AvePoolBackward(const int nthreads, const Dtype* top_diff,
    const int num, const int channels, const int height, const int width, const int pooled_height, const int pooled_width,
    const int kernel_h, const int kernel_w, const int stride_h, const int stride_w, const int pad_h, const int pad_w,
    Dtype* bottom_diff) 
{
  CUDA_KERNEL_LOOP(index, nthreads) 
  {
    int w = index % width + pad_w;
    int h = (index / width) % height + pad_h;
    int c = (index / width / height) % channels;
    int n = index / width / height / channels;
    int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    int phend = min(h / stride_h + 1, pooled_height);
    int pwstart = (w < kernel_w) ? 0 : (w - kernel_w) / stride_w + 1;
    int pwend = min(w / stride_w + 1, pooled_width);
    Dtype gradient = 0;
    top_diff += (n * channels + c) * pooled_height * pooled_width;
    for (int ph = phstart; ph < phend; ++ph) 
      for (int pw = pwstart; pw < pwend; ++pw) 
      {
        int hstart = ph * stride_h - pad_h;
        int wstart = pw * stride_w - pad_w;
        int hend = min(hstart + kernel_h, height + pad_h);
        int wend = min(wstart + kernel_w, width + pad_w);
        int pool_size = (hend - hstart) * (wend - wstart);
        gradient += top_diff[ph * pooled_width + pw] / pool_size;
      }
    bottom_diff[index] = gradient;
  }
}
//--------------------------------------------------------------------------------------
template <typename Dtype>
void PoolingLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom, const vector<Blob<Dtype>*>& top) 
{
	int num = bottom[0]->num();
	int channels = bottom[0]->channels();
	int height = bottom[0]->height();
	int width = bottom[0]->width();
	
	const Dtype* bottom_data = bottom[0]->gpu_data();
	Dtype* top_data = top[0]->mutable_gpu_data();
	int count = top[0]->count();
	int* mask = NULL;
	if (this->layer_param_.pooling_param().global_pool() == false)
	{
		if (this->layer_param_.pooling_param().pool() == "max") 
		{
			mask = max_idx_.mutable_gpu_data();    
			MaxPoolForward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>
			(   count, bottom_data,
					num, channels, height, width, pooled_height_, pooled_width_, 
					kernel_size_, kernel_size_, stride_, stride_, pad_, pad_, 
					top_data, mask);  
		}
		else if (this->layer_param_.pooling_param().pool() == "ave") 
		{
			AvePoolForward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>
			(   count, bottom_data, 
					num, channels, height, width, pooled_height_, pooled_width_, 
					kernel_size_, kernel_size_, stride_, stride_, pad_, pad_, 
					top_data);	
		}	
		else
			LOG(FATAL)<<"unsupported";
	}
	else
	{
		if (this->layer_param_.pooling_param().pool() == "max") 
		{   
			mask = max_idx_.mutable_gpu_data();    
			MaxPoolForward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>
			(   count, bottom_data,
				  num, channels, height, width, pooled_height_, pooled_width_, 
					height, width, height, width, 0, 0, 
				  top_data, mask);  
		}
		else if (this->layer_param_.pooling_param().pool() == "ave") 
		{
			AvePoolForward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>
			(   count, bottom_data, 
					num, channels, height, width, pooled_height_, pooled_width_, 
					height, width, height, width, 0, 0, 
					top_data);	

		}
		else
			LOG(FATAL)<<"unsupported";	
	}	
	
}

template <typename Dtype>
void PoolingLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top, const vector<Blob<Dtype>*>& bottom) 
{

 	int num = bottom[0]->num();
	int channels = bottom[0]->channels();
	int height = bottom[0]->height();
	int width = bottom[0]->width();
		
	 
	const Dtype* top_diff = top[0]->gpu_diff();
	Dtype* bottom_diff = bottom[0]->mutable_gpu_diff();
	const int count = bottom[0]->count();
	caffe_gpu_set(count, Dtype(0.), bottom_diff);
	const int* mask = NULL;
	if (this->layer_param_.pooling_param().global_pool() == false)
	{ 
		if (this->layer_param_.pooling_param().pool() == "max") 
		{
			mask = max_idx_.gpu_data();    
			MaxPoolBackward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>
			(   count, top_diff, mask, 
					num, channels, height, width, pooled_height_, pooled_width_,
					kernel_size_, kernel_size_, stride_, stride_, pad_, pad_, 
					bottom_diff); 
		}
		else if (this->layer_param_.pooling_param().pool() == "ave") 
		{
			AvePoolBackward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>
			(   count, top_diff, 
					num, channels, height, width, pooled_height_, pooled_width_, 
					kernel_size_, kernel_size_, stride_, stride_, pad_, pad_, 
					bottom_diff);
		}
		else
			LOG(FATAL)<<"unsupported";	
	}
	else
	{
		if (this->layer_param_.pooling_param().pool() == "max") 
		{
			mask = max_idx_.gpu_data();    
			MaxPoolBackward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>
			(   count, top_diff, mask, 
					num, channels, height, width, pooled_height_, pooled_width_,
					height, width, height, width, 0, 0, 
					bottom_diff); 
		}
		else if (this->layer_param_.pooling_param().pool() == "ave") 
		{
			AvePoolBackward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>
			(   count, top_diff, 
					num, channels, height, width, pooled_height_, pooled_width_, 
					height, width, height, width, 0, 0, 
					bottom_diff);
		}
		else
			LOG(FATAL)<<"unsupported";	
	}
}
	
template <typename Dtype>
void PoolingLayer<Dtype>::SecForward_gpu(const vector<Blob<Dtype>*>& bottom, const vector<Blob<Dtype>*>& top) 
{
	int num = bottom[0]->num();
	int channels = bottom[0]->channels();
	int height = bottom[0]->height();
	int width = bottom[0]->width();
	
	const Dtype* bottom_data = bottom[0]->gpu_data();
	Dtype* top_data = top[0]->mutable_gpu_data();
	int count = top[0]->count();
	int* mask = NULL;
	
	
	AvePoolForward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>
			(   count, bottom[0]->gpu_sec_diff(), 
					num, channels, height, width, pooled_height_, pooled_width_, 
					kernel_size_, kernel_size_, stride_, stride_, pad_, pad_, 
					top[0]->mutable_gpu_sec_diff());	
}


INSTANTIATE_LAYER_GPU_FUNCS(PoolingLayer);


}  // namespace caffe
